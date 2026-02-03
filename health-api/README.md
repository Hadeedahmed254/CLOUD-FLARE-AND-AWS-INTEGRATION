# Health Check API

Production-ready health check API for Cloudflare Load Balancer integration with AWS multi-region infrastructure.

## Features

- ✅ **Basic Health Check** (`/health`) - Simple endpoint for load balancer monitoring
- ✅ **Detailed Health Check** (`/health/detailed`) - Comprehensive system status
- ✅ **API Status** (`/api/status`) - API service health
- ✅ **Static Content** (`/static`) - Cached content testing
- ✅ **Docker Support** - Production-ready containerization
- ✅ **Environment Variables** - Configurable deployment

## Endpoints

### GET /
Returns API information and available endpoints.

### GET /health
Simple health check endpoint for Cloudflare Load Balancer.

**Response:**
```json
{
  "status": "healthy",
  "timestamp": "2024-02-03T08:00:00.000Z"
}
```

### GET /health/detailed
Detailed health check with system information.

**Response:**
```json
{
  "status": "healthy",
  "timestamp": "2024-02-03T08:00:00.000Z",
  "uptime": 3600,
  "memory": {
    "used": "50 MB",
    "total": "512 MB"
  },
  "region": "us-east-1",
  "version": "1.0.0"
}
```

### GET /api/status
API service status endpoint.

### GET /static
Static content endpoint for caching tests.

## Running Locally

```bash
# Install dependencies
npm install

# Start server
npm start

# Development mode with auto-reload
npm run dev
```

## Docker Deployment

```bash
# Build image
docker build -t health-api .

# Run container
docker run -p 3000:3000 -e AWS_REGION=us-east-1 health-api
```

## Environment Variables

- `PORT` - Server port (default: 3000)
- `AWS_REGION` - AWS region identifier (default: us-east-1)
- `NODE_ENV` - Environment (development/production)

## Health Check Configuration

### Cloudflare Load Balancer
- **Path**: `/health`
- **Expected Status**: 200
- **Expected Body**: `"healthy"`
- **Interval**: 30 seconds
- **Timeout**: 10 seconds
- **Retries**: 2

### AWS Application Load Balancer
- **Path**: `/health/detailed`
- **Expected Status**: 200
- **Interval**: 30 seconds
- **Healthy Threshold**: 2
- **Unhealthy Threshold**: 3

## Author

**Hadeed Ahmed**
- Email: hadeeda5@gmail.com
- GitHub: @hadeedahmed254

## License

MIT
