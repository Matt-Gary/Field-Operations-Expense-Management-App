# ENTERPRISE Ops — Field Operations & Expense Management

[![Flutter](https://img.shields.io/badge/Flutter-Frontend-02569B?logo=flutter)](https://flutter.dev/)
[![Node.js](https://img.shields.io/badge/Node.js-Backend-339933?logo=node.js)](https://nodejs.org/)
[![MySQL](https://img.shields.io/badge/MySQL-Databases-4479A1?logo=mysql)](https://www.mysql.com/)

A comprehensive, production-grade platform managing field service requests, vehicle trip logs, multi-tiered expense approvals, and site surveys. Built to handle complex business logic, strict data auditing, and dynamic role-based access for field technicians and managers.

> 🎥 **Watch the Video Presentation:** [YouTube Link](https://youtu.be/j9yXjX_1DrM)

---

## 🎯 Executive Summary

The ENTERPRISE Ops application bridges the gap between field technicians and administrative management by providing a robust mobile/web interface backed by a highly secure and optimized Node.js API. 

**This is not just a CRUD application.** It actively validates complex operational constraints in real-time, such as preventing time overlaps in field tasks, dynamically routing permissions, and proxying sensitive documents seamlessly from an internal GLPI system without exposing core database endpoints.

---

## 🏗 System Architecture & Tech Stack

### Frontend (Cross-Platform Flutter)
- **Framework**: Flutter (Web, Android, iOS, Desktop)
- **Key Patterns**: Responsive design, robust state management, and real-time form validations.

### Backend (Node.js / Express)
- **Core Engine**: Node.js with Express.js handling RESTful routing.
- **Middleware**: `multer` for robust multipart file handling; `sharp` for on-the-fly image optimization to reduce database and bandwidth overhead.
- **Database Architecture**: Dual MySQL instances ensuring separation of concerns.
  - `enterprise DB`: Stores operational telemetry, expenses, trips, fleet registration, and caching.
  - `GLPI DB`: Direct integration for authentication, enterprise task tracking, and role verification.

---

## 🚀 Key Engineering Showcases

### 1. Complex Task & Time Management
- **Time Overlap Protection**: Cross-references scheduled tasks during field operations to prevent technicians from double-booking hours (`H.h`). It detects parallel "in progress" states and intelligently pauses workflows to ensure precise telemetry.
- **Dynamic Pre-Approvals**: System caches frequent routine patterns to bypass repetitive form configurations, significantly improving UX in the field and minimizing human error.

### 2. Multi-Tiered Approval Engine & Security Proxy
- **Expense Control Workflows**: Complete lifecycle management for field expenses including cryptographic evidence attachments, status tracking, and hierarchical sign-offs.
- **Auto-Correction Loop**: When a manager denies an expense, the entry resets intuitively back to "Awaiting Approval" only if the user actively modifies a rejected attribute (e.g., uploading a clearer receipt), preventing strict database duplication.
- **Document Security Proxy**: Files are streamed directly from the internal GLPI server to the client through the Node API. This bridge ensures the mobile client never retains complex session logic or exposes vulnerable enterprise authentication tokens.

### 3. Image Optimization Pipeline
- **Bandwidth & Storage Efficiency**: Multi-file photographic uploads are intercepted at the server level, automatically downscaled, and converted to progressive JPEGs before hitting the data layer. This drastically optimizes long-term AWS/storage costs and mobile payload sizes for technicians in low-signal areas.

### 4. Fleet Telemetry & Knowledge Management
- **Trip Lifecycle Verification**: Implements a strict gating system requiring accurately localized start points, destinations, and mandatory timestamped photographic evidence of odometer readings prior to authorizing vehicle usage.

---

## ⚙️ Core Backend Logic Explained

### Photo Upload & Enterprise Linkage (`/upload-documents`)
1. **Intercept**: Global interception via `multer` for incoming file blobs.
2. **Process**: Compression and sanitization handled securely via `sharp`.
3. **Enterprise Sync**: API execution to register a new authenticated `Document` inside the enterprise GLPI architecture.
4. **Relational Linkage**: Securing a `Document_Item` link, tying the processed photo directly to an active field `ProjectTask`.
5. **Local Telemetry**: The local operational `enterprise` database is synchronized with fast-retrieval reference pointers, avoiding BLOB storage in standard tables.

---

## 🛠 Getting Started

### Prerequisites
- [Flutter SDK](https://docs.flutter.dev/get-started/install) (latest stable)
- [Node.js](https://nodejs.org/) 18+
- Two MySQL databases (Enterprise app data schema and GLPI enterprise schema)

### Running the Application Locally

**1. Initialize the Server:**
```bash
cd "enterprise backend"
npm install
node index.js
```

**2. Launch the Client Engine:**
```bash
cd enterprise
# Fetch packages
flutter pub get 
# Run for the web/emulator
flutter run
```

---
*Designed, architected, and built to solve robust operational challenges at scale.*
