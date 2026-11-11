package main

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestLoadConfig(t *testing.T) {
	t.Setenv("PORT", "9090")
	t.Setenv("LOG_LEVEL", "warn")
	t.Setenv("APP_ENV", "staging")
	t.Setenv("APP_VERSION", "1.2.3")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.port != "9090" || cfg.logLevel != slog.LevelWarn || cfg.env != "staging" || cfg.version != "1.2.3" {
		t.Fatalf("unexpected config: %+v", cfg)
	}

	t.Setenv("PORT", "bad")
	if _, err := loadConfig(); err == nil {
		t.Fatal("expected error for invalid PORT")
	}

	t.Setenv("PORT", "8080")
	t.Setenv("LOG_LEVEL", "verbose")
	if _, err := loadConfig(); err == nil {
		t.Fatal("expected error for invalid LOG_LEVEL")
	}
}

func TestEndpointsAndMetrics(t *testing.T) {
	var logs bytes.Buffer
	var draining atomic.Bool
	log := slog.New(slog.NewJSONHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	h := newApp(config{port: "8080", logLevel: slog.LevelDebug, env: "test", version: "0.1.0-test"}, log, &draining)

	// GET /
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET / status = %d, want 200", rec.Code)
	}
	var root map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &root); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if root["message"] != "Hello from DevOps Task!" || root["status"] != "running" || root["version"] != "0.1.0-test" {
		t.Fatalf("unexpected root payload: %v", root)
	}

	// GET /health (200 while up, 503 while draining)
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/health", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /health status = %d, want 200", rec.Code)
	}
	draining.Store(true)
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/health", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("draining /health status = %d, want 503", rec.Code)
	}

	// 404 and 405
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/unknown", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("GET /unknown status = %d, want 404", rec.Code)
	}
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST / status = %d, want 405", rec.Code)
	}

	// GET /metrics
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /metrics status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	for _, want := range []string{"http_requests_total", "http_errors_total", "http_request_duration_seconds_bucket", `path="/other"`} {
		if !strings.Contains(body, want) {
			t.Fatalf("missing %q in /metrics output", want)
		}
	}

	firstLine, _, _ := strings.Cut(logs.String(), "\n")
	var entry map[string]any
	if err := json.Unmarshal([]byte(firstLine), &entry); err != nil {
		t.Fatalf("expected JSON log line, got %q (%v)", firstLine, err)
	}
	if entry["path"] != "/" || entry["level"] != "INFO" {
		t.Fatalf("unexpected log fields: %v", entry)
	}
}

func TestGracefulShutdown(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	_ = ln.Close()

	t.Setenv("PORT", port)
	t.Setenv("LOG_LEVEL", "info")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan error, 1)
	go func() { done <- run(ctx) }()

	client := &http.Client{
		Timeout:   time.Second,
		Transport: &http.Transport{DisableKeepAlives: true},
	}
	ready := false
	for range 20 {
		resp, err := client.Get("http://127.0.0.1:" + port + "/health")
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				ready = true
				break
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
	if !ready {
		t.Fatal("server did not become ready in time")
	}

	if code := healthcheck(); code != 0 {
		t.Fatalf("healthcheck() = %d, want 0", code)
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("shutdown error: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("shutdown timed out")
	}
}
