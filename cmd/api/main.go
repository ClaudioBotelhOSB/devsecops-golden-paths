// Package main is the generic backend API service scaffold for the
// Zero-Trust Golden Path. It is the workload that backend-ci builds,
// signs, attests, pushes, and deploys to preview, staging, and production
// via Argo Rollouts.
//
// Treat this file as a starting point: replace the in-memory node store
// with your real domain model, keep the /healthz, /readyz, and /metrics
// endpoints so the existing k6, Playwright, Patrol, and Argo analysis
// templates keep working without modification.
//
// The service name is read at runtime from SERVICE_NAME (falling back to
// the compile-time default below) so the same binary can represent any
// service without a recompile.
//
// Owner: platform engineering (PLATFORM_OWNER env var at runtime).
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
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const defaultServiceName = "backend-api"

// serviceName is resolved at startup: SERVICE_NAME env var overrides the
// compile-time default. Exposed via Prometheus const labels so the Argo
// canary analysis can slice by service without recompiling per deployment.
var serviceName = func() string {
	if v := os.Getenv("SERVICE_NAME"); v != "" {
		return v
	}
	return defaultServiceName
}()

// defaultOwner is pulled from PLATFORM_OWNER at startup. It has no
// compile-time fallback so a forgotten value surfaces as an empty string
// instead of silently branding every record with the template author.
var defaultOwner = os.Getenv("PLATFORM_OWNER")

// ----------------------------------------------------------------------------
// Domain
// ----------------------------------------------------------------------------

type Node struct {
	Name      string    `json:"name"`
	Region    string    `json:"region"`
	Owner     string    `json:"owner"`
	CreatedAt time.Time `json:"created_at"`
}

type nodeStore struct {
	mu    sync.RWMutex
	items map[string]Node
}

func newNodeStore() *nodeStore {
	return &nodeStore{items: make(map[string]Node)}
}

func (s *nodeStore) list() []Node {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Node, 0, len(s.items))
	for _, n := range s.items {
		out = append(out, n)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (s *nodeStore) create(n Node) (Node, error) {
	if n.Name == "" {
		return Node{}, errors.New("name required")
	}
	if n.Owner == "" {
		n.Owner = defaultOwner
	}
	n.CreatedAt = time.Now().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.items[n.Name] = n
	return n, nil
}

// ----------------------------------------------------------------------------
// Metrics
// ----------------------------------------------------------------------------

type metrics struct {
	reqs     *prometheus.CounterVec
	duration *prometheus.HistogramVec
	inflight prometheus.Gauge
}

func newMetrics(reg prometheus.Registerer) *metrics {
	f := promauto.With(reg)
	return &metrics{
		reqs: f.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "HTTP requests by route and status.",
			ConstLabels: prometheus.Labels{
				"service": serviceName,
			},
		}, []string{"route", "method", "status"}),
		duration: f.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request duration in seconds.",
			Buckets: prometheus.DefBuckets,
			ConstLabels: prometheus.Labels{
				"service": serviceName,
			},
		}, []string{"route", "method"}),
		inflight: f.NewGauge(prometheus.GaugeOpts{
			Name: "http_inflight_requests",
			Help: "In-flight HTTP requests.",
			ConstLabels: prometheus.Labels{
				"service": serviceName,
			},
		}),
	}
}

// instrument wraps a handler with Prometheus observation.
func (m *metrics) instrument(route string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		m.inflight.Inc()
		defer m.inflight.Dec()

		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		h(sw, r)

		elapsed := time.Since(start).Seconds()
		m.duration.WithLabelValues(route, r.Method).Observe(elapsed)
		m.reqs.WithLabelValues(route, r.Method, fmt.Sprintf("%d", sw.status)).Inc()
	}
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (sw *statusWriter) WriteHeader(code int) {
	sw.status = code
	sw.ResponseWriter.WriteHeader(code)
}

// ----------------------------------------------------------------------------
// HTTP server
// ----------------------------------------------------------------------------

type server struct {
	store   *nodeStore
	log     *slog.Logger
	metrics *metrics
	ready   bool
	readyMu sync.RWMutex
}

func newServer(log *slog.Logger, m *metrics) *server {
	return &server{
		store:   newNodeStore(),
		log:     log,
		metrics: m,
		ready:   true,
	}
}

func (s *server) setReady(ok bool) {
	s.readyMu.Lock()
	defer s.readyMu.Unlock()
	s.ready = ok
}

func (s *server) isReady() bool {
	s.readyMu.RLock()
	defer s.readyMu.RUnlock()
	return s.ready
}

func (s *server) routes(mux *http.ServeMux) {
	mux.Handle("/healthz", s.metrics.instrument("/healthz", s.healthz))
	mux.Handle("/readyz", s.metrics.instrument("/readyz", s.readyz))
	mux.Handle("/v1/nodes", s.metrics.instrument("/v1/nodes", s.nodes))
}

func (s *server) healthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte("ok"))
}

func (s *server) readyz(w http.ResponseWriter, _ *http.Request) {
	if !s.isReady() {
		http.Error(w, "not ready", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte("ready"))
}

func (s *server) nodes(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	switch r.Method {
	case http.MethodGet:
		payload := map[string]any{"items": s.store.list()}
		_ = json.NewEncoder(w).Encode(payload)
	case http.MethodPost:
		var n Node
		if err := json.NewDecoder(r.Body).Decode(&n); err != nil {
			http.Error(w, fmt.Sprintf("invalid body: %v", err), http.StatusBadRequest)
			return
		}
		created, err := s.store.create(n)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(created)
	default:
		w.Header().Set("Allow", strings.Join([]string{http.MethodGet, http.MethodPost}, ", "))
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// ----------------------------------------------------------------------------
// Bootstrap
// ----------------------------------------------------------------------------

func main() {
	var (
		httpAddr    string
		metricsAddr string
		logLevel    string
	)
	flag.StringVar(&httpAddr, "http-addr", ":8080", "HTTP API listen address.")
	flag.StringVar(&metricsAddr, "metrics-addr", ":9090", "Prometheus /metrics listen address.")
	flag.StringVar(&logLevel, "log-level", "info", "Log level: debug | info | warn | error.")
	flag.Parse()

	log := newLogger(logLevel)

	reg := prometheus.NewRegistry()
	reg.MustRegister(prometheus.NewGoCollector())
	reg.MustRegister(prometheus.NewProcessCollector(prometheus.ProcessCollectorOpts{}))
	m := newMetrics(reg)

	srv := newServer(log, m)

	apiMux := http.NewServeMux()
	srv.routes(apiMux)

	metricsMux := http.NewServeMux()
	metricsMux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{Registry: reg}))

	api := &http.Server{
		Addr:              httpAddr,
		Handler:           apiMux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       20 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	mx := &http.Server{
		Addr:              metricsAddr,
		Handler:           metricsMux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	errCh := make(chan error, 2)
	go func() {
		log.Info("api listening", slog.String("addr", httpAddr))
		if err := api.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- fmt.Errorf("api: %w", err)
		}
	}()
	go func() {
		log.Info("metrics listening", slog.String("addr", metricsAddr))
		if err := mx.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- fmt.Errorf("metrics: %w", err)
		}
	}()

	select {
	case <-ctx.Done():
		log.Info("shutdown requested")
	case err := <-errCh:
		log.Error("server error", slog.Any("err", err))
	}

	srv.setReady(false)

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()
	_ = api.Shutdown(shutdownCtx)
	_ = mx.Shutdown(shutdownCtx)
	log.Info("api shutdown clean", slog.String("owner", defaultOwner), slog.String("service", serviceName))
}

func newLogger(level string) *slog.Logger {
	var lvl slog.Level
	switch level {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl})
	return slog.New(h).With(
		slog.String("service", serviceName),
		slog.String("maintainer", defaultOwner),
	)
}
