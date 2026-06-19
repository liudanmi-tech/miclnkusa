# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Workflow Rules (Non-Negotiable)

Before touching any code, answer these three questions:
1. Which other files import the file being changed?
2. Which callers invoke the function/interface being changed?
3. Which features need manual verification after the change?

Then follow this sequence:
1. `git status` — confirm clean working tree
2. `git checkout -b fix/description` or `feat/description`
3. Make the minimal change
4. Show `git diff` and wait for user confirmation before committing
5. One commit per independent feature — never batch unrelated changes

**Hard limits:** No direct commits to `main`/`master`. No more than 3 files per commit (unless refactoring). Never "fix" adjacent code that wasn't requested.

---

## Project Structure

This is a **full-stack mobile app**: iOS client (SwiftUI) + Python backend (FastAPI).

```
0226new/
├── Models.swift/WorkSurvivalGuide/   ← iOS Xcode project (edit here, NOT iOS_Code_Files/)
├── server_code/                       ← Python FastAPI backend
│   ├── main.py                        ← Monolith entry point (~5700 lines)
│   ├── api/                           ← Modularized API routes
│   │   ├── assistant.py               ← AI chat endpoints
│   │   ├── live_sessions.py           ← Live recording endpoints
│   │   └── profiles.py                ← Contact/profile endpoints
│   └── services/                      ← Stateful service layer
│       ├── voiceprint_service.py      ← Voice embedding extraction
│       ├── voiceprint_matcher.py      ← Speaker identification
│       ├── live_turn_processor.py     ← Real-time transcript processing
│       └── knowledge_graph.py         ← Persistent memory (KG tables)
├── doc/                               ← Architecture & design docs (read before coding)
└── iOS_Code_Files/                    ← Backup only — never modify this
```

---

## iOS Development

**Xcode project:** `Models.swift/WorkSurvivalGuide/WorkSurvivalGuide.xcodeproj`

**Build:** Open in Xcode (16+), Cmd+R. No CLI build needed for day-to-day work.

**New Swift files** do NOT need to be added to `project.pbxproj` — the project uses `PBXFileSystemSynchronizedRootGroup`, so any `.swift` file dropped into the directory is automatically compiled.

**Key files:**
- `Shared/AppConfig.swift` — environment switching (test vs prod, mock data). Toggle `useTestServer` here.
- `Services/NetworkManager.swift` — **single entry point** for all API calls. Every new API endpoint must add a method here.
- `Models/Task.swift` — core data model; many views depend on it

**Environment switching** (in `AppConfig.swift`):
- Test server: `34.74.255.48` (used when `useTestServer = true` in DEBUG builds)
- Production server: `34.74.150.225`
- `useMockData = true` bypasses all network calls

**iOS MVVM pattern:**
- Views own no business logic — all state lives in `@StateObject`/`@ObservedObject` ViewModels
- `TaskListViewModel.shared` is a singleton used across multiple views for the task list
- `NotificationCenter` is the inter-component communication bus (e.g., `NewTaskCreated`, `ChatSessionDeleted`, `TaskAnalysisCompleted`)

---

## Server Development

**SSH access:**
```bash
ssh gemini-server   # SSH config: host=gemini-server, user=liudanmi_gmail_com, key=~/.ssh/id_rsa
```

**Logs (on server):**
```bash
sudo journalctl -u gemini-audio.service -f
# or
tail -f ~/gemini-audio-service.log
```

**Deployment — no git on server, use scp:**
```bash
scp server_code/api/assistant.py gemini-server:~/api/assistant.py
scp server_code/main.py gemini-server:~/main.py
# Then restart:
ssh gemini-server "sudo systemctl restart gemini-audio.service"
```

**Run locally:**
```bash
cd server_code
pip install -r requirements.txt
# Requires .env with GEMINI_API_KEY, DATABASE_URL, PROXY_URL
uvicorn main:app --reload --port 8000
```

**Run server-side tests:**
```bash
cd server_code
python3 test_profiles_api.py
python3 scripts/test_gemini_connection.py
```

**Variable naming gotcha:** In `main.py`, the base URL variable is named `baseURLForRead` (not `baseURL`).

---

## Architecture: How Features Are Wired

### Recording → Analysis Flow

1. iOS taps record → `RecordingViewModel` → `AudioRecorderService` captures PCM
2. On stop → `NetworkManager.uploadAudio()` → `POST /api/v1/audio/upload`
3. Server: Gemini transcribes + extracts dialogue/emotion → writes `AnalysisResult`
4. iOS polls `GET /sessions/{id}/status` → when `completed`, fetches detail
5. Server: Skill matching → parallel strategy card generation → scene image generation
6. iOS displays `TaskDetailView` with cards + images

### AI Chat Flow

1. iOS taps chat button → `RecordingViewModel.createChatSession()` → `POST /assistant/init-chat-session`
2. `ContentView` observes `recordingViewModel.chatSessionId != nil` → presents `ChatAIAssistantView` fullscreen
3. User sends message → `ChatAIAssistantViewModel.send()` → SSE stream from `POST /assistant/chat`
4. On exit with conversation → `POST /assistant/close-chat-session` → posts `ChatSessionClosed` notification
5. On exit without input → `deleteOrphanSession()` → `DELETE /sessions/{id}` → posts `ChatSessionDeleted`

**Critical:** `TaskListViewModel.addNewTask()` must NOT call `setProcessing()` for chat sessions (`sessionType == "chat"`) — doing so locks the recording button.

### Live Session Flow

1. iOS → `POST /api/v1/live/sessions` → WebSocket audio stream
2. Server: Deepgram processes PCM frames in real-time → transcript turns
3. Per turn: extract audio by timestamp → voice embedding → match against profiles
4. SSE events pushed to iOS: `speaker_identified`, `turn_completed`, `session_end`
5. After end: background task runs Gemini post-processing (summary, image generation)

### Skill Matching

Two paths depending on entry point:
- **AI Chat** (`assistant.py`): Uses `use_groq=True` → Groq `llama-3.1-8b-instant` (with Gemini fallback)
- **Recording/Live** (`main.py`, `live_turn_processor.py`): Uses Gemini `gemini-2.5-flash-lite` via `match_skills()` wrapper

Scoring thresholds: score ≥ 90 to include; max 3 skills per category; `emotion_recognition` always prepended.

### Voice Speaker Identification

- Chinese audio: CAM++ model (separate embeddings in `voice_embedding_zh` column)
- English audio: ECAPA model (`voice_embedding` column)
- Matching is per-turn (not cumulative) to avoid embedding distortion
- Profiles store embeddings; new recordings match against them

---

## Key Architectural Constraints

- **`iOS_Code_Files/`** is a read-only backup. All iOS edits go to `Models.swift/WorkSurvivalGuide/`.
- **`NetworkManager.swift`** is the iOS API gateway — every new backend endpoint needs a corresponding method there.
- **Server has no git.** Deployment is always via `scp`. The server's running code can differ from the local repo.
- **`main.py` is a monolith.** New independent features should go in `api/` or `services/`, not inline in `main.py`.
- **PostgreSQL is local to the VM** (not RDS). Schema changes require SSH access to run migrations.
- **Cloudflare R2** stores audio files and generated images. The bucket URL is in `AppConfig` and server `.env`.

---

## Documentation

Before working on a module, read the relevant doc in `doc/`:
- `architecture.md` — system overview, infrastructure, data flow diagrams
- `0615新对话交互.md` — current state of AI chat (SSE events, skill matching, known bugs)
- `voiceprint-matching.md` — live mode speaker ID details
- `skill-matching-logic.md` — complete skill matching algorithm
- `modules/` — per-module deep dives
