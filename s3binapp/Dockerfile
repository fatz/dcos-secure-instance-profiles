FROM golang:alpine as builder
RUN apk --no-cache add git
RUN apk update && apk add ca-certificates && rm -rf /var/cache/apk/*
RUN mkdir /build
WORKDIR /build

COPY go.mod .
COPY go.sum .
COPY s3bin.go .

ENV GO111MODULE=on
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -ldflags '-extldflags "-static"' -o main .

FROM alpine
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /build/main /app/
WORKDIR /app
CMD ["./main"]
