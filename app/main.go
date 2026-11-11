package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var version = "0.1.0"

type config struct {
	port     string
	logLevel slog.Level
	env      string
	version  string
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func main() {
	hc := flag.Bool("healthcheck", false, "probe local /health endpoint")
	flag.Parse()
	if *hc {
		os.Exit(healthcheck())
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if err := run(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func loadConfig() (config, error) {
	port := envOr("PORT", "8080")
	if p, err := strconv.Atoi(port); err != nil || p < 1 || p > 65535 {
		return config{}, fmt.Errorf("invalid PORT %q", port)
	}

	var lvl slog.Level
	switch strings.ToLower(envOr("LOG_LEVEL", "info")) {
	case "debug":
		lvl = slog.LevelDebug
	case "info":
		lvl = slog.LevelInfo
	case "warn", "warning":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		return config{}, fmt.Errorf("invalid LOG_LEVEL %q", os.Getenv("LOG_LEVEL"))
	}

	return config{
		port:     port,
		logLevel: lvl,
		env:      envOr("APP_ENV", "local"),
		version:  envOr("APP_VERSION", version),
	}, nil
}

func envOr(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

func newApp(cfg config, log *slog.Logger, draining *atomic.Bool) http.Handler {
	reg := prometheus.NewRegistry()
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	reqTotal := prometheus.NewCounterVec(
		prometheus.CounterOpts{Name: "http_requests_total", Help: "Total HTTP requests."},
		[]string{"method", "path", "status"},
	)
	errTotal := prometheus.NewCounterVec(
		prometheus.CounterOpts{Name: "http_errors_total", Help: "Total HTTP 4xx/5xx responses."},
		[]string{"method", "path", "status"},
	)
	latency := prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency in seconds.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"method", "path"},
	)
	reg.MustRegister(reqTotal, errTotal, latency)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{
			"message": "Hello from DevOps Task!",
			"status":  "running",
			"version": cfg.version,
		})
	})
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		if draining != nil && draining.Load() {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "shutting_down"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "healthy"})
	})
	mux.Handle("GET /metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		mux.ServeHTTP(sw, r)

		// Bucket unknown paths together to keep Prometheus/Loki label cardinality bounded.
		route := "/other"
		switch r.URL.Path {
		case "/", "/health", "/metrics":
			route = r.URL.Path
		}

		dur := time.Since(start)
		code := strconv.Itoa(sw.status)
		reqTotal.WithLabelValues(r.Method, route, code).Inc()
		latency.WithLabelValues(r.Method, route).Observe(dur.Seconds())
		if sw.status >= 400 {
			errTotal.WithLabelValues(r.Method, route, code).Inc()
		}

		lvl := slog.LevelInfo
		if sw.status >= 500 {
			lvl = slog.LevelError
		} else if sw.status >= 400 {
			lvl = slog.LevelWarn
		}

		log.Log(r.Context(), lvl, "http_request",
			"env", cfg.env,
			"version", cfg.version,
			"method", r.Method,
			"path", route,
			"uri", r.URL.Path,
			"status", sw.status,
			"duration_ms", float64(dur.Microseconds())/1000.0,
		)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func run(ctx context.Context) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.logLevel}))
	var draining atomic.Bool

	srv := &http.Server{
		Addr:              ":" + cfg.port,
		Handler:           newApp(cfg, log, &draining),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("server_started", "port", cfg.port, "env", cfg.env, "version", cfg.version)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
		close(errCh)
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		log.Info("shutdown_initiated")
		draining.Store(true)
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			return err
		}
		log.Info("server_stopped")
		return nil
	}
}

func healthcheck() int {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + envOr("PORT", "8080") + "/health")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		return 0
	}
	return 1
}
