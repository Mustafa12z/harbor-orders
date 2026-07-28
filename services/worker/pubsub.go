package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

func receiveMessages(ctx context.Context) []pulledMessage {
	project := os.Getenv("GCP_PROJECT")
	sub := os.Getenv("PUBSUB_SUBSCRIPTION")
	if project != "" && sub != "" {
		msgs, err := pullPubSub(ctx, project, sub)
		if err != nil {
			log.Printf("Pub/Sub pull error: %v", err)
			return nil
		}
		return msgs
	}
	// Local SQS path is a stub (LocalStack); nothing to receive without AWS SDK.
	_ = os.Getenv("SQS_QUEUE_URL")
	return nil
}

type pulledMessage struct {
	Data        string
	AckID       string
	Subscription string
}

func pullPubSub(ctx context.Context, project, subscription string) ([]pulledMessage, error) {
	token, err := gcpAccessToken()
	if err != nil {
		return nil, err
	}
	url := fmt.Sprintf("https://pubsub.googleapis.com/v1/projects/%s/subscriptions/%s:pull", project, subscription)
	body, _ := json.Marshal(map[string]interface{}{
		"maxMessages": 10,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("pull status %d: %s", resp.StatusCode, string(b))
	}
	var parsed struct {
		ReceivedMessages []struct {
			AckID   string `json:"ackId"`
			Message struct {
				Data string `json:"data"`
			} `json:"message"`
		} `json:"receivedMessages"`
	}
	if err := json.Unmarshal(b, &parsed); err != nil {
		return nil, err
	}
	out := make([]pulledMessage, 0, len(parsed.ReceivedMessages))
	for _, m := range parsed.ReceivedMessages {
		raw, err := base64.StdEncoding.DecodeString(m.Message.Data)
		if err != nil {
			continue
		}
		out = append(out, pulledMessage{
			Data:         string(raw),
			AckID:        m.AckID,
			Subscription: subscription,
		})
	}
	return out, nil
}

func ackPubSub(project, subscription string, ackIDs []string) error {
	if len(ackIDs) == 0 {
		return nil
	}
	token, err := gcpAccessToken()
	if err != nil {
		return err
	}
	url := fmt.Sprintf("https://pubsub.googleapis.com/v1/projects/%s/subscriptions/%s:acknowledge", project, subscription)
	body, _ := json.Marshal(map[string]interface{}{"ackIds": ackIDs})
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
		return fmt.Errorf("ack status %d: %s", resp.StatusCode, string(b))
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
