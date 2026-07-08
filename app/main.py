"""FastAPI application entry point for Sparks AI Brain microservice."""

import logging
from contextlib import asynccontextmanager

import uvicorn
from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from app.auth import verify_api_key
from app.config import settings
from app.models import HarvestRequest, HarvestResponse
from app.services import analyze_search_terms

logging.basicConfig(
    level=logging.DEBUG if settings.DEBUG else logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler for startup and shutdown events."""
    logger.info("Starting %s v%s", settings.APP_NAME, settings.APP_VERSION)
    logger.info(
        "Gemini config loaded | model=%s | key_length=%d | key_fingerprint=%s",
        settings.GEMINI_MODEL,
        len(settings.GEMINI_API_KEY),
        settings.gemini_api_key_fingerprint,
    )
    yield
    logger.info("Shutting down %s", settings.APP_NAME)


app = FastAPI(
    title=settings.APP_NAME,
    version=settings.APP_VERSION,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/")
async def root():
    """Default health check endpoint for AWS App Runner."""
    return {"status": "ok"}


@app.get("/health")
async def health_check():
    """Return service health status without authentication."""
    return {
        "status": "healthy",
        "service": settings.APP_NAME,
        "version": settings.APP_VERSION,
        "model": settings.GEMINI_MODEL,
    }


@app.post(
    "/api/agent/harvest",
    response_model=HarvestResponse,
)
async def harvest_search_terms(
    request: HarvestRequest,
    _: str = Depends(verify_api_key),
):
    """Analyze search term performance and return optimization actions."""
    logger.info(
        "Harvest request: campaign='%s', search_terms=%d",
        request.campaign_name,
        len(request.search_terms),
    )

    try:
        response = await analyze_search_terms(request)
        logger.info("Harvest complete: %d actions returned", len(response.actions))
        return response

    except ValueError as exc:
        logger.exception("Invalid AI response for campaign '%s'", request.campaign_name)
        raise HTTPException(
            status_code=422,
            detail={"error": "ai_response_invalid", "message": str(exc)},
        ) from exc

    except RuntimeError as exc:
        logger.exception("AI service unavailable for campaign '%s'", request.campaign_name)
        raise HTTPException(
            status_code=503,
            detail={"error": "ai_service_unavailable", "message": str(exc)},
        ) from exc

    except Exception:
        logger.exception("Unexpected error for campaign '%s'", request.campaign_name)
        raise HTTPException(
            status_code=500,
            detail={
                "error": "internal_error",
                "message": "An unexpected error occurred",
            },
        )


if __name__ == "__main__":
    uvicorn.run(
        "app.main:app",
        host=settings.HOST,
        port=settings.PORT,
        reload=settings.DEBUG,
    )
