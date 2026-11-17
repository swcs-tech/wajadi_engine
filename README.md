# Wajadi Engine 🚀

Wajadi Engine is an **Elixir & Phoenix** backend engine designed for **WhatsApp multi-session management** and intelligent **AI Customer Service Agents** powered by **LangChain**. It features multi-account and multi-store support, product catalog management, and automated replies with LLM tool calling.

---

## 📋 Key Features

- **Multi-Session WhatsApp Management**: Powered by [Amarula](https://amarula.hexdocs.pm/), enabling concurrent and isolated WhatsApp sessions across multiple accounts.
- **PostgreSQL Session Storage**: Authentication credentials and chat history are safely stored in PostgreSQL and automatically restored upon server restarts.
- **AI Store Assistant (LangChain)**: LLM auto-replies (OpenAI-compatible) with customizable store personalities and automated function/tool calling for catalog lookups.
- **Multi-Tenant / Multi-Store Architecture**: Organize multiple stores, product catalogs, and assigned WhatsApp sessions per business account.
- **Session Lifecycle & Cleanup**: Full lifecycle handling including QR code pairing (API & terminal), pause, resume, disconnect, logout, soft-delete (archive), and background purge tasks.
- **Monitoring & Observability**: Integrated Phoenix LiveDashboard with Ecto database metrics and Telemetry at `/dev/dashboard`.

---

## ⚡ Quick Start

### 1. Prerequisites

Ensure your system has the following installed:
- **Erlang/OTP**: 28
- **Elixir**: 1.20
- **PostgreSQL**: 18

### 2. Project Setup

Clone the repository and fetch dependencies:

```bash
git clone <repository-url>
cd wajadi_engine
mix deps.get
```

### 3. Environment Configuration (`.env`)

Create a `.env` file in the root directory (or use the template below):

```env
# Database
DATABASE_URL=postgres://postgres:postgres@localhost:5432/wajadi_engine_dev

# Phoenix Endpoint
SECRET_KEY_BASE=your_long_random_secret_key_base_here
PORT=4000

# AI Configuration (OpenAI-compatible endpoint)
NINE_ROUTER_BASE_URL=https://api.openai.com/v1
NINE_ROUTER_API_KEY=your-api-key-here
NINE_ROUTER_MODEL=gpt-4o

# WhatsApp & Session Settings
PRINT_WA_QR=true
WAJADI_SESSION_CLEANUP_ENABLED=false
```

> **Tip**: Generate a secure secret key by running `mix phx.gen.secret`.

### 4. Database Setup

Create the database, run migrations, and run seeds:

```bash
mix ecto.setup
```

*(This runs `ecto.create`, `ecto.migrate`, and `seeds.exs`)*

### 5. Running the Application

Start the server inside an interactive IEx session:

```bash
iex -S mix phx.server
```

Or start without IEx:

```bash
mix phx.server
```

The application will be accessible at:
- **API Base URL**: `http://localhost:4000/api`
- **LiveDashboard (Dev Mode)**: `http://localhost:4000/dev/dashboard`

---

## 🛠️ API Reference

### 1. WhatsApp Session Management (`/api/whatsapp`)

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/account/:user_id/list` | List all sessions for a user account |
| `POST` | `/account/:user_id/create` | Create a new session |
| `GET` | `/account/:user_id/qr/:session_id/view` | View session QR code (SVG / raw) |
| `GET` | `/account/:user_id/qr/:session_id/refresh` | Force refresh session QR code |
| `PATCH` | `/account/:user_id/connect/:session_id` | Connect session to WhatsApp network |
| `PATCH` | `/account/:user_id/disconnect/:session_id`| Disconnect session |
| `PATCH` | `/account/:user_id/pause/:session_id` | Temporarily pause AI auto-replies |
| `PATCH` | `/account/:user_id/resume/:session_id` | Resume AI auto-replies |
| `DELETE` | `/account/:user_id/logout/:session_id` | Log out from WhatsApp Web |
| `DELETE` | `/account/:user_id/delete/:session_id` | Delete/archive session |

### 2. Accounts, Stores & Products (`/api/account/:account_id`)

| Method | Endpoint | Description |
|---|---|---|
| `GET` / `POST` | `/stores` | List stores / create a store |
| `PATCH` / `DELETE` | `/stores/:store_id` | Update store / archive store |
| `GET` / `PUT` | `/stores/:store_id/personality` | Get / upsert AI store personality & prompt |
| `GET` / `POST` | `/stores/:store_id/products` | List products / create a product |
| `PATCH` / `DELETE`| `/stores/:store_id/products/:id` | Update product / archive product |
| `PATCH` | `/sessions/:session_id/store` | Assign/move WhatsApp session to a store |

---

## 🧪 Testing & Code Quality

Run tests, formatting, and linters:

```bash
# Run unit & integration tests
mix test

# Credo static code analysis
mix credo --all

# Precommit check (strict compilation, unused dependencies, formatting, and tests)
mix precommit
```

---

## 🧹 Maintenance & Background Tasks

### Purging Expired Sessions

To permanently delete expired archived WhatsApp sessions and their associated files:

```bash
mix wajadi.sessions.purge --batch-size 100
```
