package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
)

// Event represents a message from the event bus
type Event struct {
	Type      string                 `json:"type"`
	Payload   map[string]interface{} `json:"payload"`
	Timestamp string                 `json:"timestamp"`
}

func main() {
	hasPubSub := os.Getenv("PUBSUB_SUBSCRIPTION") != "" && os.Getenv("GCP_PROJECT") != ""
	hasSQS := os.Getenv("SQS_QUEUE_URL") != ""
	if !hasPubSub && !hasSQS {
		log.Fatal("PUBSUB_SUBSCRIPTION+GCP_PROJECT or SQS_QUEUE_URL is required")
	}

	otelShutdown, err := initOTel(context.Background(), "worker")
	if err != nil {
		log.Printf("WARNING: OpenTelemetry init failed: %v", err)
		otelShutdown = func(context.Context) error { return nil }
	}
	defer flushTraces(otelShutdown)

	// Internal service URLs for event-driven calls
	services := map[string]string{
		"inventory":    getEnv("INVENTORY_SERVICE_URL", "http://inventory-service:8082"),
		"payment":      getEnv("PAYMENT_SERVICE_URL", "http://payment-service:8083"),
		"notification": getEnv("NOTIFICATION_SERVICE_URL", "http://notification-service:8084"),
		"shipping":     getEnv("SHIPPING_SERVICE_URL", "http://shipping-service:8085"),
		"order":        getEnv("ORDER_SERVICE_URL", "http://order-service:8081"),
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Health check endpoint
	go func() {
		mux := http.NewServeMux()
		mux.HandleFunc("/livez", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
		mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]string{"status": "ok", "service": "worker"})
		})
		port := getEnv("HEALTH_PORT", "8090")
		log.Printf("Worker health check on :%s", port)
		http.ListenAndServe(":"+port, mux)
	}()

	// Graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		log.Println("Shutting down worker...")
		cancel()
	}()

	if hasPubSub {
		log.Println("Worker started, polling Pub/Sub for events...")
	} else {
		log.Println("Worker started, polling SQS stub for events...")
	}
	pollAndProcess(ctx, services)
}

func pollAndProcess(ctx context.Context, services map[string]string) {
	client := &http.Client{
		Timeout:   10 * time.Second,
		Transport: otelhttp.NewTransport(http.DefaultTransport),
	}
	project := os.Getenv("GCP_PROJECT")

	for {
		select {
		case <-ctx.Done():
			log.Println("Worker stopped")
			return
		default:
			messages := receiveMessages(ctx)

			var ackIDs []string
			for _, msg := range messages {
				var event Event
				if err := json.Unmarshal([]byte(msg.Data), &event); err != nil {
					log.Printf("Failed to parse event: %v", err)
					continue
				}

				log.Printf("Processing event: %s", event.Type)

				if err := handleEvent(ctx, client, services, event); err != nil {
					log.Printf("Failed to handle event %s: %v", event.Type, err)
					continue
				}

				log.Printf("Successfully processed: %s", event.Type)
				if msg.AckID != "" {
					ackIDs = append(ackIDs, msg.AckID)
				}
			}

			if len(ackIDs) > 0 {
				sub := os.Getenv("PUBSUB_SUBSCRIPTION")
				if err := ackPubSub(project, sub, ackIDs); err != nil {
					log.Printf("Pub/Sub ack failed: %v", err)
				}
			}

			if len(messages) == 0 {
				time.Sleep(5 * time.Second)
			}
		}
	}
}

func handleEvent(ctx context.Context, client *http.Client, services map[string]string, event Event) error {
	_, span := otel.Tracer("worker").Start(ctx, "handle."+event.Type)
	defer span.End()
	span.SetAttributes(
		attribute.String("messaging.operation", "process"),
		attribute.String("messaging.message.type", event.Type),
	)

	switch event.Type {

	case "order.created":
		return handleOrderCreated(client, services, event.Payload)

	case "order.status_changed":
		newStatus, _ := event.Payload["new_status"].(string)
		orderID := asInt(event.Payload["order_id"])
		customerID, _ := event.Payload["customer_id"].(string)

		switch newStatus {
		case "processing":
			log.Printf("  -> Creating shipment for order %d", orderID)
			return createShipment(client, services, event.Payload)

		case "shipped":
			log.Printf("  -> Sending shipping notification for order %d", orderID)
			return sendNotification(client, services, customerID, "order_shipped", map[string]interface{}{
				"OrderID":        orderID,
				"TrackingNumber": event.Payload["tracking_number"],
			})

		case "delivered":
			log.Printf("  -> Sending delivery notification for order %d", orderID)
			return sendNotification(client, services, customerID, "order_delivered", map[string]interface{}{
				"OrderID": orderID,
			})

		case "cancelled":
			log.Printf("  -> Releasing inventory for cancelled order %d", orderID)
			_, _ = postJSON(client, services["inventory"]+"/release", map[string]interface{}{"order_id": orderID}, nil)
			return nil
		}

	case "payment.completed":
		orderID := asInt(event.Payload["order_id"])
		log.Printf("  -> Payment completed for order %d (confirm if still pending)", orderID)
		_ = updateOrderStatus(client, services, orderID, "confirmed")
		return nil

	case "payment.failed":
		orderID := asInt(event.Payload["order_id"])
		customerID, _ := event.Payload["customer_id"].(string)
		log.Printf("  -> Payment failed for order %d, cancelling", orderID)
		_, _ = postJSON(client, services["inventory"]+"/release", map[string]interface{}{"order_id": orderID}, nil)
		_ = updateOrderStatus(client, services, orderID, "cancelled")
		_ = sendNotification(client, services, customerID, "payment_failed", map[string]interface{}{
			"OrderID": orderID,
		})
		return nil

	case "shipment.created":
		log.Printf("  -> Shipment created for order %v", event.Payload["order_id"])
		return nil

	case "shipment.delivered":
		orderID := asInt(event.Payload["order_id"])
		customerID, _ := event.Payload["customer_id"].(string)
		log.Printf("  -> Shipment delivered for order %d", orderID)
		_ = updateOrderStatus(client, services, orderID, "delivered")
		_ = sendNotification(client, services, customerID, "order_delivered", map[string]interface{}{
			"OrderID": orderID,
		})
		return nil

	default:
		log.Printf("  -> Unknown event type: %s (skipping)", event.Type)
	}
	return nil
}

func handleOrderCreated(client *http.Client, services map[string]string, payload map[string]interface{}) error {
	orderID := asInt(payload["order_id"])
	customerID, _ := payload["customer_id"].(string)
	total := asFloat(payload["total"])
	currency, _ := payload["currency"].(string)
	if currency == "" {
		currency = "GBP"
	}

	items := normalizeItems(payload["items"])
	log.Printf("  -> Reserving inventory for order %d (%d items)", orderID, len(items))
	reserveBody := map[string]interface{}{
		"order_id": orderID,
		"items":    items,
	}
	if status, err := postJSON(client, services["inventory"]+"/reserve", reserveBody, nil); err != nil || status >= 400 {
		log.Printf("  -> Reservation failed for order %d: status=%d err=%v", orderID, status, err)
		_ = updateOrderStatus(client, services, orderID, "cancelled")
		return fmt.Errorf("reserve failed: status=%d err=%v", status, err)
	}

	log.Printf("  -> Charging payment for order %d", orderID)
	chargeBody := map[string]interface{}{
		"order_id":    orderID,
		"customer_id": customerID,
		"amount":      total,
		"currency":    currency,
		"method":      "card",
	}
	var chargeResp map[string]interface{}
	status, err := postJSON(client, services["payment"]+"/charge", chargeBody, &chargeResp)
	if err != nil || status >= 400 || fmt.Sprint(chargeResp["status"]) == "failed" {
		log.Printf("  -> Payment failed for order %d: status=%d err=%v", orderID, status, err)
		_, _ = postJSON(client, services["inventory"]+"/release", map[string]interface{}{"order_id": orderID}, nil)
		_ = updateOrderStatus(client, services, orderID, "cancelled")
		_ = sendNotification(client, services, customerID, "payment_failed", map[string]interface{}{
			"OrderID": orderID,
		})
		return fmt.Errorf("charge failed: status=%d err=%v", status, err)
	}

	log.Printf("  -> Sending order confirmation for order %d", orderID)
	_ = sendNotification(client, services, customerID, "order_confirmed", map[string]interface{}{
		"OrderID":      orderID,
		"CustomerName": customerID,
		"Currency":     currency,
		"Total":        total,
	})

	log.Printf("  -> Confirming order %d", orderID)
	return updateOrderStatus(client, services, orderID, "confirmed")
}

func createShipment(client *http.Client, services map[string]string, payload map[string]interface{}) error {
	orderID := asInt(payload["order_id"])
	customerID, _ := payload["customer_id"].(string)
	if customerID == "" {
		customerID = "Customer"
	}

	// Prefer shipping details embedded in order notes (JSON from storefront).
	ship := parseShippingNotes(payload["notes"])
	name := ship["name"]
	if name == "" {
		name = customerID
	}
	line1 := ship["address_line1"]
	if line1 == "" {
		line1 = "1 High Street"
	}
	city := ship["city"]
	if city == "" {
		city = "London"
	}
	postcode := ship["postcode"]
	if postcode == "" {
		postcode = "E1 1AA"
	}

	body := map[string]interface{}{
		"order_id":       orderID,
		"carrier":        "royal_mail",
		"recipient_name": name,
		"address_line1":  line1,
		"address_line2":  ship["address_line2"],
		"city":           city,
		"postcode":       postcode,
		"country":        "GB",
		"weight_kg":      1.0,
	}
	status, err := postJSON(client, services["shipping"]+"/shipments", body, nil)
	if err != nil || status >= 400 {
		return fmt.Errorf("create shipment failed: status=%d err=%v", status, err)
	}
	return nil
}

func sendNotification(client *http.Client, services map[string]string, recipient, template string, data map[string]interface{}) error {
	if recipient == "" {
		recipient = "customer@example.com"
	}
	body := map[string]interface{}{
		"recipient": recipient,
		"channel":   "email",
		"template":  template,
		"data":      data,
	}
	status, err := postJSON(client, services["notification"]+"/send", body, nil)
	if err != nil || status >= 400 {
		return fmt.Errorf("notify %s failed: status=%d err=%v", template, status, err)
	}
	return nil
}

func updateOrderStatus(client *http.Client, services map[string]string, orderID int, newStatus string) error {
	body := map[string]interface{}{
		"order_id":   orderID,
		"new_status": newStatus,
	}
	status, err := putJSON(client, services["order"]+"/status", body, nil)
	if err != nil || status >= 400 {
		return fmt.Errorf("status update to %s failed: status=%d err=%v", newStatus, status, err)
	}
	return nil
}

func postJSON(client *http.Client, url string, body interface{}, out interface{}) (int, error) {
	return doJSON(client, http.MethodPost, url, body, out)
}

func putJSON(client *http.Client, url string, body interface{}, out interface{}) (int, error) {
	return doJSON(client, http.MethodPut, url, body, out)
}

func doJSON(client *http.Client, method, url string, body interface{}, out interface{}) (int, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return 0, err
	}
	req, err := http.NewRequest(method, url, bytes.NewReader(raw))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if out != nil && len(data) > 0 {
		_ = json.Unmarshal(data, out)
	}
	if resp.StatusCode >= 400 {
		return resp.StatusCode, fmt.Errorf("%s", string(data))
	}
	return resp.StatusCode, nil
}

func normalizeItems(raw interface{}) []map[string]interface{} {
	items := []map[string]interface{}{}
	arr, ok := raw.([]interface{})
	if !ok {
		return items
	}
	for _, it := range arr {
		m, ok := it.(map[string]interface{})
		if !ok {
			continue
		}
		items = append(items, map[string]interface{}{
			"product_id": fmt.Sprint(m["product_id"]),
			"quantity":   asInt(m["quantity"]),
		})
	}
	return items
}

func parseShippingNotes(raw interface{}) map[string]string {
	out := map[string]string{}
	s, ok := raw.(string)
	if !ok || s == "" {
		return out
	}
	var m map[string]string
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		return out
	}
	return m
}

func asInt(v interface{}) int {
	switch n := v.(type) {
	case float64:
		return int(n)
	case int:
		return n
	case int64:
		return int(n)
	case json.Number:
		i, _ := n.Int64()
		return int(i)
	case string:
		var i int
		fmt.Sscanf(n, "%d", &i)
		return i
	default:
		return 0
	}
}

func asFloat(v interface{}) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case int:
		return float64(n)
	case int64:
		return float64(n)
	case json.Number:
		f, _ := n.Float64()
		return f
	default:
		return 0
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
