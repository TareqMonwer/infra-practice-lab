import json
import logging
import os
import sys
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from starlette.middleware.base import BaseHTTPMiddleware

VERSION = os.getenv("APP_VERSION", "1.0.0")
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(level=LOG_LEVEL, stream=sys.stdout, format="%(message)s")
logger = logging.getLogger("devops-task")
REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "path", "status"])
ERRORS = Counter("http_errors_total", "HTTP error responses", ["method", "path", "status"])
LATENCY = Histogram("http_request_duration_seconds", "Request duration", ["method", "path"], buckets=(.005,.01,.025,.05,.1,.25,.5,1,2.5,5,10))
class MetricsMiddleware(BaseHTTPMiddleware):
 async def dispatch(self, request, call_next):
  start=time.perf_counter()
  try:
   response=await call_next(request)
  except Exception:
   response=Response(status_code=500)
   raise
  finally:
   elapsed=time.perf_counter()-start
   path=request.url.path if request.url.path in ("/", "/health", "/metrics") else "/other"
   status=str(response.status_code) if 'response' in locals() else "500"
   REQUESTS.labels(request.method,path,status).inc()
   LATENCY.labels(request.method,path).observe(elapsed)
   if int(status)>=400: ERRORS.labels(request.method,path,status).inc()
   logger.info(json.dumps({"timestamp":time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),"level":"ERROR" if int(status)>=500 else "INFO","environment":ENVIRONMENT,"method":request.method,"path":path,"status":int(status),"duration_ms":round(elapsed*1000,3)}))
  return response
@asynccontextmanager
async def lifespan(app):
 logger.info(json.dumps({"level":"INFO","event":"startup","environment":ENVIRONMENT,"version":VERSION}))
 yield
 logger.info(json.dumps({"level":"INFO","event":"shutdown","graceful":True}))
app=FastAPI(lifespan=lifespan)
app.add_middleware(MetricsMiddleware)
@app.get('/')
def home(): return {"message":"Hello from DevOps Task!","status":"running","version":VERSION}
@app.get('/health')
def health(): return {"status":"healthy"}
@app.get('/metrics')
def metrics(): return Response(generate_latest(),media_type=CONTENT_TYPE_LATEST)
