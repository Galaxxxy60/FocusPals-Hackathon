"""
FocusPals — Firestore Cloud Sync (Edge-to-Cloud Control Plane)

Lightweight module that logs productivity events to Google Cloud Firestore.
The Gemini agent runs locally (Edge) for latency & privacy, but telemetry
and strike logs are persisted on GCP for analytics, cross-device memory,
and to satisfy the hackathon's "must use Google Cloud" requirement.

Architecture: Privacy-First, Edge-to-Cloud
- Edge (local): screen capture, audio, OS control, Gemini Live API
- Cloud (Firestore): strike logs, session analytics, long-term memory
"""

import os
import time
import threading
import uuid
from datetime import datetime, timezone

# ─── Firestore Init ─────────────────────────────────────────
# We use a dedicated thread for all Firestore writes to avoid
# blocking the main async loop.  If Firestore is unavailable
# (no key, network issue), the app continues normally — cloud
# sync is best-effort, never blocks local functionality.

_db = None
_user_id = None  # Anonymous device ID (persisted in user_prefs)
_initialized = False


def _get_user_id() -> str:
    """Get or create a persistent anonymous device ID."""
    global _user_id
    if _user_id:
        return _user_id
    
    try:
        from audio import _load_prefs, _save_prefs
        prefs = _load_prefs()
        _user_id = prefs.get("device_id", "")
        if not _user_id:
            _user_id = str(uuid.uuid4())[:8]  # Short anonymous ID
            _save_prefs({"device_id": _user_id})
            print(f"☁️ Firestore: New device ID: {_user_id}")
    except Exception:
        _user_id = "unknown"
    return _user_id


def init_firestore():
    """Initialize Firestore client. Call once at startup.
    Uses the GCP project 'focuspals-cloud-agent'.
    Safe to fail — the app works fine without cloud sync."""
    global _db, _initialized
    
    if _initialized:
        return _db is not None
    
    _initialized = True
    
    try:
        from google.cloud import firestore
        
        # Check for service account key file
        key_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gcp_key.json")
        
        if os.path.exists(key_path):
            # Use explicit service account credentials
            os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = key_path
            _db = firestore.Client(project="focuspals-cloud-agent")
            print("☁️ Firestore: Connected via service account key ✅")
        else:
            # Try Application Default Credentials (gcloud auth application-default login)
            try:
                _db = firestore.Client(project="focuspals-cloud-agent")
                print("☁️ Firestore: Connected via ADC (gcloud auth) ✅")
            except Exception:
                print("☁️ Firestore: No credentials found — cloud sync disabled")
                print("   To enable: run 'gcloud auth application-default login'")
                print(f"   Or place service account key at: {key_path}")
                return False
        
        # Write a connection test document
        _get_user_id()
        _fire_and_forget(_write_heartbeat)
        return True
        
    except ImportError:
        print("☁️ Firestore: google-cloud-firestore not installed — cloud sync disabled")
        print("   Install with: pip install google-cloud-firestore")
        return False
    except Exception as e:
        print(f"☁️ Firestore: Init failed ({e}) — cloud sync disabled")
        return False


def _fire_and_forget(fn, *args, **kwargs):
    """Run a Firestore write in a background thread — never blocks."""
    def _wrapper():
        try:
            fn(*args, **kwargs)
        except Exception as e:
            print(f"☁️ Firestore write error (non-critical): {e}")
    
    t = threading.Thread(target=_wrapper, daemon=True)
    t.start()


# ─── Firestore Writers ──────────────────────────────────────

def _write_heartbeat():
    """Write a heartbeat document to verify connectivity."""
    if not _db:
        return
    user_id = _get_user_id()
    _db.collection("devices").document(user_id).set({
        "last_seen": datetime.now(timezone.utc),
        "app": "FocusPals",
        "version": "1.0.0",
    }, merge=True)
    print(f"☁️ Firestore: Heartbeat written for device {user_id}")


def log_strike(target_title: str, reason: str, mode: str):
    """Log a strike event (tab/window closure) to Firestore.
    Called from fire_hand_animation() after a successful close."""
    if not _db:
        return
    
    def _write():
        user_id = _get_user_id()
        _db.collection("users").document(user_id)\
           .collection("strikes").add({
            "timestamp": datetime.now(timezone.utc),
            "target": target_title[:100],  # Truncate for privacy
            "reason": reason[:200],
            "mode": mode,  # "browser" or "app"
            "device_id": user_id,
        })
        print(f"☁️ Firestore: Strike logged → '{target_title[:40]}'")
    
    _fire_and_forget(_write)


def log_session_start(session_duration_minutes: int, language: str):
    """Log session start to Firestore. Returns session_doc_id for later update."""
    if not _db:
        return None
    
    user_id = _get_user_id()
    session_id = f"session_{int(time.time())}"
    
    def _write():
        _db.collection("users").document(user_id)\
           .collection("sessions").document(session_id).set({
            "start_time": datetime.now(timezone.utc),
            "planned_duration_min": session_duration_minutes,
            "language": language,
            "device_id": user_id,
            "status": "active",
        })
        print(f"☁️ Firestore: Session started (id={session_id})")
    
    _fire_and_forget(_write)
    return session_id


def log_session_end(session_id: str, actual_duration_min: float, strikes_count: int, summary: str = None):
    """Update session document with end-of-session data."""
    if not _db or not session_id:
        return
    
    def _write():
        user_id = _get_user_id()
        update_data = {
            "end_time": datetime.now(timezone.utc),
            "actual_duration_min": round(actual_duration_min, 1),
            "strikes_count": strikes_count,
            "status": "completed",
        }
        if summary:
            update_data["summary"] = summary[:2000]
        
        _db.collection("users").document(user_id)\
           .collection("sessions").document(session_id).update(update_data)
        print(f"☁️ Firestore: Session ended (id={session_id}, {actual_duration_min:.0f}min, {strikes_count} strikes)")
    
    _fire_and_forget(_write)


def log_productivity_pulse(suspicion: float, alignment: float, category: str, window_title: str):
    """Log a productivity snapshot (called periodically during deep work).
    Sampled sparingly to avoid excessive writes."""
    if not _db:
        return
    
    def _write():
        user_id = _get_user_id()
        _db.collection("users").document(user_id)\
           .collection("pulses").add({
            "timestamp": datetime.now(timezone.utc),
            "suspicion": round(suspicion, 2),
            "alignment": round(alignment, 2),
            "category": category,
            "window": window_title[:60],
            "device_id": user_id,
        })
    
    _fire_and_forget(_write)
