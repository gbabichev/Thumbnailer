# 📷 Thumbnailer 

A powerful **macOS app** for managing and processing photo & video
collections with **automated thumbnail generation**, **contact sheet
creation**, and smart media organization tools. ✨

------------------------------------------------------------------------

## 🖥️ Screenshots 

<p align="center">
    <a href="Documentation/App1.png"><img src="Documentation/App1.png" width="45%"></a>
    <a href="Documentation/App2.png"><img src="Documentation/App2.png" width="45%"></a>
</p>

------------------------------------------------------------------------

### 🔍 Smart Content Detection

-   Auto-switches between **Photo Mode** and **Video Mode**
-   Supports major formats: JPG, HEIC, PNG, HEIC, MP4, and more

### 📸 Photo Processing

-   **Thumbnail Generation** 🖼️ → JPEG / HEIC, adjustable quality &
    sizing
-   **Contact Sheets** 🗂️ → Grid layouts (Stretch, Crop, Pad),
    customizable columns (1-20)
-   **SMB Optimized** ⚡ → Efficient on network drives

### 🎬 Video Processing

-   **Video Contact Sheets** 🎞️ → Smart frame sampling & layout
-   **Trim Intros/Outros** ✂️ → Cut seconds off start/end
-   **Flatten Folders** 📂 → Move videos up one level

### 🛠️ Specialized Tools

-   **Photo Tools**
    - Scan non-HEIC/JPEG
    - Convert to JPG / HEIC
    - Validate that thumbnails exist
    - Detect folders with low photo count (customizable)
    - Delete folders with no contact sheets
-   **Video Tools**
    - Scan for Non-MP4's 
    - Identify short videos (customizable)
    - Trim MP4 intros (customizable)
    - Trim MP4 outros (customizable)
    - Move videos from individual subfolders to their parent folder.
    - Delete videos with no contact sheets in the parent. 

------------------------------------------------------------------------

## ⚡ Processing Modes

-   **Batch Processing** 🧩 → Multiple folders at once, with progress &
    logs
-   **Smart Performance** 🚦 → Priority-aware, concurrent,
    memory-efficient

------------------------------------------------------------------------

## 🖥️ User Interface

-   **Folder Management** 📂 → Drag-drop, table view, bulk actions
-   **Live Logging** 📜 → Real-time feedback, exportable
-   **Progress Tracking** ⏳ → Bars, percentages, stall detection

------------------------------------------------------------------------

## 🔔 Notifications & Status

-   **macOS Notifications** 🖥️ → Banner alerts when done
-   **Dock Badges** 🎯 → Show completion state
-   **Audio Alerts** 🔊 → For long jobs

------------------------------------------------------------------------

## 🗂️ File Format Support

-   **Images** → JPG, PNG, HEIC, TIFF, BMP, WebP, GIF
-   **Videos** → MP4 fully supported; others detected but limited

------------------------------------------------------------------------

## 🛡️ Technical Features

-   **Reliability** ✅ Atomic file ops, error recovery, cancellation
-   **Performance** ⚡ ImageIO downsampling, concurrency, background
    priority
-   **Logging** 📝 Persistent logs in `~/Library/Logs/Thumbnailer/`

