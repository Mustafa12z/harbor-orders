package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
)

func initOTel(ctx context.Context, serviceName string) (func(context.Context) error, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		return func(context.Context) error { return nil }, nil
	}

	res, err := resource.New(ctx,
		resource.WithFromEnv(),
		resource.WithAttributes(semconv.ServiceName(serviceName)),
	)
	if err != nil {
		return nil, err
	}

	opts := []otlptracehttp.Option{}
	switch {
	case strings.HasPrefix(endpoint, "https://"):
		opts = append(opts, otlptracehttp.WithEndpointURL(endpoint))
	case strings.HasPrefix(endpoint, "http://"):
		opts = append(opts,
			otlptracehttp.WithEndpoint(strings.TrimPrefix(endpoint, "http://")),
			otlptracehttp.WithInsecure(),
		)
	default:
		opts = append(opts, otlptracehttp.WithEndpoint(endpoint), otlptracehttp.WithInsecure())
	}

	exporter, err := otlptracehttp.New(ctx, opts...)
	if err != nil {
		return nil, err
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(traceSampler()),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	log.Printf("OpenTelemetry tracing enabled -> %s (service=%s)", endpoint, serviceName)
	return tp.Shutdown, nil
}

func traceSampler() sdktrace.Sampler {
	arg := os.Getenv("OTEL_TRACES_SAMPLER_ARG")
	if arg == "" {
		return sdktrace.ParentBased(sdktrace.AlwaysSample())
	}
	ratio, err := strconv.ParseFloat(arg, 64)
	if err != nil || ratio < 0 || ratio > 1 {
		return sdktrace.ParentBased(sdktrace.AlwaysSample())
	}
	if ratio >= 1 {
		return sdktrace.ParentBased(sdktrace.AlwaysSample())
	}
	if ratio <= 0 {
		return sdktrace.ParentBased(sdktrace.NeverSample())
	}
	return sdktrace.ParentBased(sdktrace.TraceIDRatioBased(ratio))
}

func withOTelHTTP(h http.Handler, operation string) http.Handler {
	return otelhttp.NewHandler(h, operation)
}

func flushTraces(shutdown func(context.Context) error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = shutdown(ctx)
}
