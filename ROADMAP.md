# 🚀 Teleprompt by rocs — Feature Roadmap & Missing Tools

This document outlines the current feature set, proposed roadmap, and technical specifications for upcoming studio tools.

---

## 🟢 Currently Implemented Features

- [x] **Teleprompter Studio**:
  - Live camera preview with front & rear camera support.
  - Variable prompt scroll speed ($0.5\times - 3.0\times$) & text size ($16\text{px} - 36\text{px}$).
  - Camera preview mirror toggle.
  - Prompt vertical positioning (Top, Middle, Bottom).
  - Portrait & Landscape capture orientation support.
  - Fullscreen immersive studio preview mode.
  - Countdown timer ($3, 2, 1$) and live recording timer.
- [x] **Interactive Bouncy Captions & Subtitles**:
  - Auto-generated word-level timestamp alignment based on script & recording duration.
  - Bouncy elastic word pop animations (`AnimatedScale` with `Curves.elasticOut`).
  - Movable gesture layer (drag & position subtitles anywhere on screen).
  - Tap-to-edit inline word editor dialog.
  - Preset subtitle styles (`Bouncy Yellow`, `Neon Cyan`, `Minimal White`).
- [x] **In-App Video Playback**:
  - Tap-to-play video stage with time readout (`00:05 / 00:24`) and scrubber bar.
- [x] **Gallery Export & Video Sharing**:
  - Save video directly to device photo gallery (`gal`).
  - Native share sheet integration (`share_plus`).
- [x] **Studio Feature Selection Hub & Branding**:
  - Branded app title: *Teleprompt by rocs*.
  - Native splash screen setup.
  - Feature selection dashboard landing page.

---

## 🟡 Proposed Features & Missing Tools Roadmap

### 1. 🤖 AI & Voice Automation Tools
- [ ] **AI Voice-Driven Teleprompter (Speech-Following Auto-Scroll)**:
  - Use real-time speech recognition (`speech_to_text`) to scroll the prompt only as the speaker pronounces each word.
- [ ] **AI Script Writer & Assistant**:
  - Topic-to-script generator powered by Gemini / LiteRT / OpenAI to write structured, ready-to-read scripts from short prompts.

### 2. 🎬 Video Editing & Export Tools
- [ ] **Burned-In Animated Subtitle Exporter**:
  - Burn the custom bouncy subtitles directly into the exported MP4 video file using `ffmpeg_kit_flutter`.
- [ ] **Auto Silence & Pause Trimmer**:
  - Detect and remove silent pauses at the beginning, middle, or end of a video take.
- [ ] **Social Media Aspect Ratio Converter**:
  - One-tap export presets for 9:16 (TikTok / Reels / Shorts), 1:1 (Instagram Feed), and 16:9 (YouTube).

### 3. 📹 Camera & Audio Enhancements
- [ ] **Camera Touch Focus & Exposure Slider**:
  - Tap-to-focus and exposure compensation controls on the live camera stage.
- [ ] **AI Background Blur / Green Screen**:
  - Real-time portrait background blur and background replacement.
- [ ] **Voice Noise Cleaner & Audio Equalizer**:
  - Ambient noise reduction and speech clarity enhancement.

### 4. 📲 Remote Control & Hardware Workflows
- [ ] **Bluetooth Page-Turner / Remote Control**:
  - Control scroll speed, play/pause, and text size using a Bluetooth remote or secondary device.
