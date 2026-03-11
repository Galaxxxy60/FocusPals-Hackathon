"""
FocusPals — Crash Logger & File Logging
Captures all stdout/stderr to a rotating log file and dumps state on crash.
Must be initialized BEFORE any other module prints anything.
"""

import os
import sys
import time
import traceback
import json
import atexit
from datetime import datetime
from logging.handlers import RotatingFileHandler
import logging

# ─── Log Directory ───────────────────────────────────────────
_agent_dir = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.join(_agent_dir, "logs")
os.makedirs(LOG_DIR, exist_ok=True)

# Log file: tama_YYYYMMDD_HHMMSS.log (one per launch)
_launch_ts = datetime.now().strftime("%Y%m%d_%H%M%S")
LOG_FILE = os.path.join(LOG_DIR, f"tama_{_launch_ts}.log")

# Also keep a "latest.log" symlink/copy for quick access
LATEST_LOG = os.path.join(LOG_DIR, "latest.log")


# ─── Tee: Write to both console and file ─────────────────────

class TeeWriter:
    """Duplicates writes to both the original stream and a log file."""
    
    def __init__(self, original_stream, log_file_handle):
        self._original = original_stream
        self._log = log_file_handle
    
    def write(self, text):
        if text:  # skip empty writes
            try:
                self._original.write(text)
                self._original.flush()
            except Exception:
                pass
            try:
                self._log.write(text)
                self._log.flush()
            except Exception:
                pass
    
    def flush(self):
        try:
            self._original.flush()
        except Exception:
            pass
        try:
            self._log.flush()
        except Exception:
            pass
    
    # Support for fileno() — some libraries need it
    def fileno(self):
        return self._original.fileno()
    
    def isatty(self):
        return False
    
    @property
    def encoding(self):
        return getattr(self._original, 'encoding', 'utf-8')


# ─── State Dump on Crash ─────────────────────────────────────

def _dump_state_to_log(log_handle):
    """Dump the current Tama state dict to the log for post-mortem analysis."""
    try:
        from config import state
        log_handle.write("\n" + "=" * 60 + "\n")
        log_handle.write("📋 TAMA STATE DUMP AT CRASH TIME\n")
        log_handle.write("=" * 60 + "\n")
        
        # Serialize state, handling non-serializable values
        safe_state = {}
        for k, v in list(state.items()):  # Snapshot: prevent RuntimeError if state is mutated during crash
            try:
                json.dumps(v)  # test if serializable
                safe_state[k] = v
            except (TypeError, ValueError):
                safe_state[k] = repr(v)
        
        log_handle.write(json.dumps(safe_state, indent=2, ensure_ascii=False))
        log_handle.write("\n" + "=" * 60 + "\n")
        log_handle.flush()
    except Exception as e:
        log_handle.write(f"\n⚠️ Could not dump state: {e}\n")
        log_handle.flush()


# ─── Crash Hook ───────────────────────────────────────────────

_log_handle = None
_original_excepthook = sys.excepthook


def _crash_excepthook(exc_type, exc_value, exc_tb):
    """Called on unhandled exceptions — logs full traceback + state dump."""
    crash_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    # Format the traceback
    tb_lines = traceback.format_exception(exc_type, exc_value, exc_tb)
    tb_text = "".join(tb_lines)
    
    crash_report = (
        "\n" + "🔴" * 30 + "\n"
        f"💥 FATAL CRASH at {crash_time}\n"
        f"Exception: {exc_type.__name__}: {exc_value}\n"
        "🔴" * 30 + "\n\n"
        f"{tb_text}\n"
    )
    
    # Write to stderr (console) — best effort
    try:
        sys.__stderr__.write(crash_report)
        sys.__stderr__.flush()
    except Exception:
        pass
    
    # Write to log file
    if _log_handle:
        try:
            _log_handle.write(crash_report)
            _dump_state_to_log(_log_handle)
            _log_handle.flush()
        except Exception:
            pass
    
    # Also save a dedicated crash file for easy finding
    try:
        crash_file = os.path.join(LOG_DIR, f"CRASH_{_launch_ts}.log")
        with open(crash_file, "w", encoding="utf-8") as f:
            f.write(crash_report)
            f.write("\n\n")
            _dump_state_to_log(f)
    except Exception:
        pass
    
    # Call original hook (so Python still prints to console normally)
    _original_excepthook(exc_type, exc_value, exc_tb)


# ─── Async Exception Catcher ─────────────────────────────────

def install_async_exception_handler(loop):
    """Install a handler for uncaught exceptions in asyncio tasks."""
    def _async_exception_handler(loop, context):
        exception = context.get("exception")
        message = context.get("message", "")
        
        crash_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        report = (
            f"\n{'🟠' * 30}\n"
            f"⚠️ ASYNC EXCEPTION at {crash_time}\n"
            f"Message: {message}\n"
        )
        
        if exception:
            tb_lines = traceback.format_exception(type(exception), exception, exception.__traceback__)
            report += f"Exception: {type(exception).__name__}: {exception}\n"
            report += "".join(tb_lines)
        
        report += f"\n{'🟠' * 30}\n"
        
        print(report)  # This will go to both console + file via Tee
        
        # Don't crash the loop — just log it
        if exception and not isinstance(exception, (asyncio.CancelledError, KeyboardInterrupt)):
            if _log_handle:
                try:
                    _dump_state_to_log(_log_handle)
                except Exception:
                    pass
    
    loop.set_exception_handler(_async_exception_handler)


# ─── Cleanup old logs ────────────────────────────────────────

def _cleanup_old_logs(max_logs=20):
    """Keep only the most recent N log files to avoid filling disk."""
    try:
        log_files = sorted(
            [f for f in os.listdir(LOG_DIR) if f.startswith("tama_") and f.endswith(".log")],
            reverse=True
        )
        for old_log in log_files[max_logs:]:
            try:
                os.remove(os.path.join(LOG_DIR, old_log))
            except Exception:
                pass
        
        # Also clean old crash files
        crash_files = sorted(
            [f for f in os.listdir(LOG_DIR) if f.startswith("CRASH_") and f.endswith(".log")],
            reverse=True
        )
        for old_crash in crash_files[max_logs:]:
            try:
                os.remove(os.path.join(LOG_DIR, old_crash))
            except Exception:
                pass
    except Exception:
        pass


# ─── Init ─────────────────────────────────────────────────────

import asyncio

def init_crash_logger():
    """Call this ONCE at the very start of tama_agent.py, before anything else."""
    global _log_handle
    
    # Clean old logs
    _cleanup_old_logs()
    
    # Open log file
    _log_handle = open(LOG_FILE, "w", encoding="utf-8", buffering=1)  # line-buffered
    
    # Write header
    _log_handle.write(f"{'=' * 60}\n")
    _log_handle.write(f"🥷 FocusPals / Tama — Session Log\n")
    _log_handle.write(f"Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    _log_handle.write(f"Python: {sys.version}\n")
    _log_handle.write(f"PID: {os.getpid()}\n")
    _log_handle.write(f"Log file: {LOG_FILE}\n")
    _log_handle.write(f"{'=' * 60}\n\n")
    _log_handle.flush()
    
    # Tee stdout and stderr
    sys.stdout = TeeWriter(sys.__stdout__, _log_handle)
    sys.stderr = TeeWriter(sys.__stderr__, _log_handle)
    
    # Install crash hook
    sys.excepthook = _crash_excepthook
    
    # Update latest.log (just overwrite with path reference)
    try:
        with open(LATEST_LOG, "w", encoding="utf-8") as f:
            f.write(f"→ {LOG_FILE}\n")
    except Exception:
        pass
    
    # Register cleanup on normal exit
    @atexit.register
    def _on_exit():
        end_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        if _log_handle:
            try:
                _log_handle.write(f"\n{'=' * 60}\n")
                _log_handle.write(f"👋 Session ended normally at {end_time}\n")
                _dump_state_to_log(_log_handle)
                _log_handle.write(f"{'=' * 60}\n")
                _log_handle.flush()
                _log_handle.close()
            except Exception:
                pass
    
    print(f"📝 Logging to: {LOG_FILE}")

    # Suppress noisy SDK logs from google.genai (AFC, HTTP requests, etc.)
    logging.getLogger("google").setLevel(logging.WARNING)
    logging.getLogger("google.genai").setLevel(logging.WARNING)

    return _log_handle

