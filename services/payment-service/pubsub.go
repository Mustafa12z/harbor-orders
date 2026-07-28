package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

func publishEvent(eventType string, payload map[string]interface{}) {
	event := map[string]interface{}{
		"type":      eventType,
		"payload":   payload,
		"timestamp": time.Now().UTC().Format(time.RFC3339),
	}
	data, err := json.Marshal(event)
	if err != nil {
		log.Printf("Event marshal error: %v", err)
		return
	}

	topic := os.Getenv("PUBSUB_TOPIC")
	project := os.Getenv("GCP_PROJECT")
	if topic != "" && project != "" {
		if err := publishPubSub(project, topic, data); err != nil {
			log.Printf("Pub/Sub publish failed: %v", err)
			return
		}
		log.Printf("Event -> Pub/Sub: %s", string(data))
		return
	}

	if os.Getenv("SQS_QUEUE_URL") != "" {
		log.Printf("Event -> SQS (local stub): %s", string(data))
		return
	}

	log.Printf("Event (no bus): %s %v", eventType, payload)
}

func publishPubSub(project, topic string, data []byte) error {
	token, err := gcpAccessToken()
	if err != nil {
		return err
	}
	url := fmt.Sprintf("https://pubsub.googleapis.com/v1/projects/%s/topics/%s:publish", project, topic)
	body, _ := json.Marshal(map[string]interface{}{
		"messages": []map[string]string{
			{"data": base64.StdEncoding.EncodeToString(data)},
		},
	})
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("pubsub status %d: %s", resp.StatusCode, string(b))
	}
	return nil
}

func gcpAccessToken() (string, error) {
	req, err := http.NewRequest(http.MethodGet, "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Metadata-Flavor", "Google")
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tok); err != nil {
		return "", err
	}
	if tok.AccessToken == "" {
		return "", fmt.Errorf("empty access token from metadata")
	}
	return tok.AccessToken, nil
}
