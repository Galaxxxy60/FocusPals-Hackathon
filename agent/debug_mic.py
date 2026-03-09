"""
FocusPals — Mic Debug Tool
Records 10 seconds of audio from the selected microphone
and saves it as a WAV file so you can hear what Gemini hears.

Usage: python debug_mic.py [mic_index]
  If no mic_index, uses default mic.
"""

import sys
import os
import wave
import struct
import math
import pyaudio

RATE = 16000
CHANNELS = 1
FORMAT = pyaudio.paInt16
CHUNK = 1024
DURATION_SECS = 10

def list_mics(pya):
    print("\n🎤 Available microphones:")
    print("-" * 60)
    for i in range(pya.get_device_count()):
        info = pya.get_device_info_by_index(i)
        if info["maxInputChannels"] > 0:
            name = info["name"]
            rate = int(info["defaultSampleRate"])
            print(f"  [{i}] {name} (rate={rate}Hz, ch={info['maxInputChannels']})")
    print("-" * 60)

def main():
    pya = pyaudio.PyAudio()
    list_mics(pya)

    mic_idx = None
    if len(sys.argv) > 1:
        mic_idx = int(sys.argv[1])
    else:
        try:
            mic_idx = pya.get_default_input_device_info()["index"]
        except Exception:
            mic_idx = 0

    info = pya.get_device_info_by_index(mic_idx)
    print(f"\n🎙️ Recording from [{mic_idx}] {info['name']}")
    print(f"   Rate: {RATE}Hz, Channels: {CHANNELS}, Duration: {DURATION_SECS}s")
    print(f"   Format: 16-bit PCM (same as what Gemini receives)\n")

    try:
        stream = pya.open(
            format=FORMAT,
            channels=CHANNELS,
            rate=RATE,
            input=True,
            input_device_index=mic_idx,
            frames_per_buffer=CHUNK,
        )
    except Exception as e:
        print(f"❌ Cannot open mic [{mic_idx}]: {e}")
        pya.terminate()
        return

    frames = []
    total_chunks = int(RATE / CHUNK * DURATION_SECS)

    print("🔴 RECORDING... Speak now!")
    print("   " + "=" * 40)

    peak_rms = 0
    for i in range(total_chunks):
        data = stream.read(CHUNK, exception_on_overflow=False)
        frames.append(data)

        # Live level meter
        n_samples = len(data) // 2
        samples = struct.unpack(f'<{n_samples}h', data)
        rms = math.sqrt(sum(s * s for s in samples) / n_samples)
        peak_rms = max(peak_rms, rms)

        # Visual meter
        bar_len = int(min(rms / 500, 1.0) * 30)
        bar = "█" * bar_len + "░" * (30 - bar_len)
        elapsed = (i + 1) * CHUNK / RATE
        sys.stdout.write(f"\r   [{bar}] {elapsed:.1f}s / {DURATION_SECS}s  RMS: {rms:.0f}")
        sys.stdout.flush()

    print("\n   " + "=" * 40)
    print("⏹️ Recording done!")

    stream.close()
    pya.terminate()

    # Save WAV
    out_path = os.path.join(os.path.dirname(__file__), "logs", "debug_mic_output.wav")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    with wave.open(out_path, 'wb') as wf:
        wf.setnchannels(CHANNELS)
        wf.setsampwidth(2)  # 16-bit = 2 bytes
        wf.setframerate(RATE)
        wf.writeframes(b''.join(frames))

    file_size = os.path.getsize(out_path)
    print(f"\n✅ Saved: {out_path}")
    print(f"   Size: {file_size / 1024:.0f} KB")
    print(f"   Peak RMS: {peak_rms:.0f}")

    if peak_rms < 50:
        print("\n⚠️  WARNING: Audio is VERY quiet! Peak RMS < 50.")
        print("   → Your mic may be muted, too far, or the wrong device.")
    elif peak_rms < 200:
        print("\n⚠️  Audio is quiet. Peak RMS < 200.")
        print("   → Try speaking louder or moving closer to the mic.")
    else:
        print(f"\n✅ Audio level looks OK (peak RMS: {peak_rms:.0f})")

    print(f"\n🎧 Open '{out_path}' to listen to what Gemini would hear.")

if __name__ == "__main__":
    main()
