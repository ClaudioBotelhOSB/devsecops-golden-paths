// Package main implements the preview-environment TTL reaper controller.
//
// Purpose
//
//	Preview environments are the single most expensive failure mode of a
//	mature delivery platform. Every PR spawns a namespaced deployment, and
//	without enforced teardown the cluster accumulates zombie namespaces
//	until the cloud bill becomes the problem. This controller is the
//	FinOps backstop that makes preview environments financially viable.
//
// Behavior
//
//  1. Every reconcile interval (default 15m) the controller lists all
//     namespaces labeled `platform.io/preview=true`.
//  2. For each namespace it reads the `platform.io/ttl` annotation
//     (Go duration string, e.g. "72h") and compares it against the
//     namespace's CreationTimestamp.
//  3. Expired namespaces are deleted. Merged-PR webhooks short-circuit
//     this by deleting immediately rather than waiting for TTL.
//  4. Metrics are exposed on :9090/metrics for Prometheus scraping.
//
// Owner: platform engineering (PLATFORM_OWNER env var at runtime).
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/homedir"
)

const (
	previewLabel    = "platform.io/preview=true"
	annotTTL        = "platform.io/ttl"
	annotOwner      = "platform.io/owner"
	annotPR         = "platform.io/pr"
	annotCostCenter = "platform.io/cost-center"
)

// defaultOwner is resolved at startup from PLATFORM_OWNER. No compile-time
// fallback: a missing value surfaces as an empty string in logs rather
// than silently branding every reap event with the template author.
var defaultOwner = func() string {
	if v := os.Getenv("PLATFORM_OWNER"); v != "" {
		return v
	}
	return ""
}()

type reaperMetrics struct {
	reconcileTotal  prometheus.Counter
	reconcileErrors prometheus.Counter
	reapSuccess     *prometheus.CounterVec
	reapErrors      *prometheus.CounterVec
	namespacesAlive prometheus.Gauge
	lastReconcileTS prometheus.Gauge
}

func newMetrics(reg prometheus.Registerer) *reaperMetrics {
	factory := promauto.With(reg)
	return &reaperMetrics{
		reconcileTotal: factory.NewCounter(prometheus.CounterOpts{
			Name: "ttl_reaper_reconcile_total",
			Help: "Total number of reconcile loops executed.",
		}),
		reconcileErrors: factory.NewCounter(prometheus.CounterOpts{
			Name: "ttl_reaper_reconcile_errors_total",
			Help: "Total number of reconcile loops that returned an error.",
		}),
		reapSuccess: factory.NewCounterVec(prometheus.CounterOpts{
			Name: "ttl_reaper_reap_success_total",
			Help: "Namespaces successfully reaped, labeled by cost_center.",
		}, []string{"cost_center"}),
		reapErrors: factory.NewCounterVec(prometheus.CounterOpts{
			Name: "ttl_reaper_reap_errors_total",
			Help: "Namespace reap failures, labeled by reason.",
		}, []string{"reason"}),
		namespacesAlive: factory.NewGauge(prometheus.GaugeOpts{
			Name: "ttl_reaper_preview_namespaces",
			Help: "Current count of live preview namespaces.",
		}),
		lastReconcileTS: factory.NewGauge(prometheus.GaugeOpts{
			Name: "ttl_reaper_last_reconcile_timestamp_seconds",
			Help: "Unix timestamp of the last reconcile loop completion.",
		}),
	}
}

// Reaper is the core controller.
type Reaper struct {
	client   kubernetes.Interface
	log      *slog.Logger
	metrics  *reaperMetrics
	interval time.Duration
	dryRun   bool
	now      func() time.Time
}

// NewReaper wires the controller. `now` is injectable for tests.
func NewReaper(client kubernetes.Interface, log *slog.Logger, m *reaperMetrics,
	interval time.Duration, dryRun bool) *Reaper {
	return &Reaper{
		client:   client,
		log:      log,
		metrics:  m,
		interval: interval,
		dryRun:   dryRun,
		now:      time.Now,
	}
}

// Run blocks until ctx is done, executing reconcile on interval.
func (r *Reaper) Run(ctx context.Context) error {
	r.log.Info("reaper starting",
		slog.Duration("interval", r.interval),
		slog.Bool("dry_run", r.dryRun),
		slog.String("owner", defaultOwner))

	if err := r.reconcile(ctx); err != nil {
		r.log.Error("initial reconcile failed", slog.Any("err", err))
	}

	t := time.NewTicker(r.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			r.log.Info("reaper stopping", slog.Any("reason", ctx.Err()))
			return nil
		case <-t.C:
			if err := r.reconcile(ctx); err != nil {
				r.log.Error("reconcile failed", slog.Any("err", err))
			}
		}
	}
}

func (r *Reaper) reconcile(ctx context.Context) error {
	r.metrics.reconcileTotal.Inc()
	defer r.metrics.lastReconcileTS.SetToCurrentTime()

	nss, err := r.client.CoreV1().Namespaces().List(ctx, metav1.ListOptions{
		LabelSelector: previewLabel,
	})
	if err != nil {
		r.metrics.reconcileErrors.Inc()
		return fmt.Errorf("list preview namespaces: %w", err)
	}

	r.metrics.namespacesAlive.Set(float64(len(nss.Items)))
	r.log.Debug("discovered preview namespaces", slog.Int("count", len(nss.Items)))

	var errs []error
	for i := range nss.Items {
		ns := &nss.Items[i]
		if err := r.evaluate(ctx, ns); err != nil {
			errs = append(errs, fmt.Errorf("ns=%s: %w", ns.Name, err))
		}
	}
	return errors.Join(errs...)
}

func (r *Reaper) evaluate(ctx context.Context, ns *corev1.Namespace) error {
	ttlStr, ok := ns.Annotations[annotTTL]
	if !ok {
		r.metrics.reapErrors.WithLabelValues("missing_ttl").Inc()
		r.log.Warn("preview namespace missing ttl annotation",
			slog.String("ns", ns.Name))
		return nil
	}

	ttl, err := time.ParseDuration(ttlStr)
	if err != nil {
		r.metrics.reapErrors.WithLabelValues("invalid_ttl").Inc()
		r.log.Warn("invalid ttl annotation",
			slog.String("ns", ns.Name),
			slog.String("ttl", ttlStr),
			slog.Any("err", err))
		return nil
	}

	age := r.now().Sub(ns.CreationTimestamp.Time)
	if age <= ttl {
		return nil
	}

	cc := ns.Annotations[annotCostCenter]
	if cc == "" {
		cc = "unknown"
	}

	logCtx := r.log.With(
		slog.String("ns", ns.Name),
		slog.String("owner", valueOr(ns.Annotations[annotOwner], defaultOwner)),
		slog.String("pr", ns.Annotations[annotPR]),
		slog.String("cost_center", cc),
		slog.Duration("age", age),
		slog.Duration("ttl", ttl),
	)

	if r.dryRun {
		logCtx.Info("would reap (dry-run)")
		return nil
	}

	logCtx.Info("reaping expired preview namespace")
	if err := r.deleteNamespace(ctx, ns.Name); err != nil {
		r.metrics.reapErrors.WithLabelValues("delete_failed").Inc()
		return fmt.Errorf("delete namespace: %w", err)
	}
	r.metrics.reapSuccess.WithLabelValues(cc).Inc()
	return nil
}

func (r *Reaper) deleteNamespace(ctx context.Context, name string) error {
	propagation := metav1.DeletePropagationForeground
	err := r.client.CoreV1().Namespaces().Delete(ctx, name, metav1.DeleteOptions{
		PropagationPolicy: &propagation,
	})
	if apierrors.IsNotFound(err) {
		return nil
	}
	return err
}

func valueOr(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}

// ------------------------------------------------------------------------
// Bootstrap
// ------------------------------------------------------------------------

func main() {
	var (
		kubeconfig  string
		interval    time.Duration
		metricsAddr string
		dryRun      bool
		logLevel    string
	)

	flag.StringVar(&kubeconfig, "kubeconfig", defaultKubeconfig(),
		"Absolute path to the kubeconfig file (defaults to in-cluster).")
	flag.DurationVar(&interval, "interval", 15*time.Minute,
		"Reconcile interval.")
	flag.StringVar(&metricsAddr, "metrics-addr", ":9090",
		"Address for the Prometheus /metrics endpoint.")
	flag.BoolVar(&dryRun, "dry-run", false,
		"Log reap decisions without deleting namespaces.")
	flag.StringVar(&logLevel, "log-level", "info",
		"Log level: debug | info | warn | error.")
	flag.Parse()

	log := newLogger(logLevel)

	cfg, err := buildConfig(kubeconfig)
	if err != nil {
		log.Error("failed to build kube config", slog.Any("err", err))
		os.Exit(1)
	}
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Error("failed to build kube client", slog.Any("err", err))
		os.Exit(1)
	}

	reg := prometheus.NewRegistry()
	reg.MustRegister(prometheus.NewGoCollector())
	reg.MustRegister(prometheus.NewProcessCollector(prometheus.ProcessCollectorOpts{}))
	metrics := newMetrics(reg)

	reaper := NewReaper(client, log, metrics, interval, dryRun)

	ctx, cancel := signal.NotifyContext(context.Background(),
		os.Interrupt, syscall.SIGTERM)
	defer cancel()

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := serveMetrics(ctx, metricsAddr, reg, log); err != nil &&
			!errors.Is(err, http.ErrServerClosed) {
			log.Error("metrics server error", slog.Any("err", err))
		}
	}()

	if err := reaper.Run(ctx); err != nil {
		log.Error("reaper exited with error", slog.Any("err", err))
		cancel()
		wg.Wait()
		os.Exit(1)
	}
	wg.Wait()
	log.Info("ttl-reaper shutdown clean")
}

func buildConfig(kubeconfig string) (*rest.Config, error) {
	if cfg, err := rest.InClusterConfig(); err == nil {
		return cfg, nil
	}
	if kubeconfig == "" {
		return nil, errors.New("not in cluster and no kubeconfig provided")
	}
	return clientcmd.BuildConfigFromFlags("", kubeconfig)
}

func defaultKubeconfig() string {
	if h := homedir.HomeDir(); h != "" {
		return filepath.Join(h, ".kube", "config")
	}
	return ""
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
		slog.String("component", "ttl-reaper"),
		slog.String("maintainer", defaultOwner),
	)
}

func serveMetrics(ctx context.Context, addr string, reg *prometheus.Registry, log *slog.Logger) error {
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{Registry: reg}))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ready"))
	})

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	log.Info("metrics server listening", slog.String("addr", addr))
	return srv.ListenAndServe()
}
