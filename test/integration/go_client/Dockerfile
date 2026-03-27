FROM golang:1.25-alpine
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
ENTRYPOINT ["go", "run", "main.go"]