const express = require('express');
/**
 * Cloudflare + AWS Health Check API
 * 
 * Production-ready health check endpoints for:
 * - Cloudflare Load Balancer monitoring
 * - AWS Application Load Balancer health checks
 * - Multi-region failover validation
 * 
 * Author: Hadeed Ahmed
 * Version: 1.0.0
 */

const os = require('os');
const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(express.json());

// Request logging
app.use((req, res, next) => {
  console.log(`${new Date().toISOString()} - ${req.method} ${req.path}`);
  next();
});

// Health check endpoint
app.get('/health', (req, res) => {
  const healthCheck = {
    status: 'healthy',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    hostname: os.hostname(),
    region: process.env.AWS_REGION || 'unknown',
    version: process.env.APP_VERSION || '1.0.0'
  };

  res.status(200).json(healthCheck);
});

// Detailed health check (for internal monitoring)
app.get('/health/detailed', (req, res) => {
  const memoryUsage = process.memoryUsage();
  const cpuUsage = process.cpuUsage();

  const detailedHealth = {
    status: 'healthy',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    hostname: os.hostname(),
    region: process.env.AWS_REGION || 'unknown',
    version: process.env.APP_VERSION || '1.0.0',
    system: {
      platform: os.platform(),
      arch: os.arch(),
      cpus: os.cpus().length,
      totalMemory: os.totalmem(),
      freeMemory: os.freemem(),
      loadAverage: os.loadavg()
    },
    process: {
      pid: process.pid,
      memory: {
        rss: `${(memoryUsage.rss / 1024 / 1024).toFixed(2)} MB`,
        heapTotal: `${(memoryUsage.heapTotal / 1024 / 1024).toFixed(2)} MB`,
        heapUsed: `${(memoryUsage.heapUsed / 1024 / 1024).toFixed(2)} MB`,
        external: `${(memoryUsage.external / 1024 / 1024).toFixed(2)} MB`
      },
      cpu: {
        user: cpuUsage.user,
        system: cpuUsage.system
      }
    }
  };

  res.status(200).json(detailedHealth);
});

// Root endpoint
app.get('/', (req, res) => {
  res.json({
    service: 'Cloudflare + AWS Health Check API',
    version: '1.0.0',
    author: 'Hadeed Ahmed',
    status: 'operational',
    endpoints: {
      health: '/health',
      detailed_health: '/health/detailed',
      api: '/api/status',
      static: '/static'
    },
    documentation: 'https://github.com/Hadeedahmed254/CLOUD-FLARE-AND-AWS-INTEGRATION'
  });
});

// API endpoint (example)
app.get('/api/status', (req, res) => {
  res.json({
    status: 'operational',
    region: process.env.AWS_REGION || 'unknown',
    timestamp: new Date().toISOString(),
    services: {
      database: 'healthy',
      cache: 'healthy',
      storage: 'healthy'
    }
  });
});

// Static content endpoint (for cache testing)
app.get('/static/:filename', (req, res) => {
  const { filename } = req.params;

  // Set cache headers
  res.set({
    'Cache-Control': 'public, max-age=86400',
    'Content-Type': 'application/json'
  });

  res.json({
    filename,
    region: process.env.AWS_REGION || 'unknown',
    timestamp: new Date().toISOString(),
    cached: true
  });
});

// Error handling
app.use((err, req, res, next) => {
  console.error('Error:', err);
  res.status(500).json({
    error: 'Internal Server Error',
    message: err.message,
    timestamp: new Date().toISOString()
  });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({
    error: 'Not Found',
    path: req.path,
    timestamp: new Date().toISOString()
  });
});

// Start server
app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
  console.log(`Region: ${process.env.AWS_REGION || 'unknown'}`);
  console.log(`Hostname: ${os.hostname()}`);
  console.log(`Environment: ${process.env.NODE_ENV || 'development'}`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down gracefully...');
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log('SIGINT received, shutting down gracefully...');
  process.exit(0);
});
