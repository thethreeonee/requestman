# requestman

> A browser extension for intercepting and modifying network requests — right inside DevTools.

**requestman** adds a **Redirect Rules** panel to your browser's DevTools (Chrome & Firefox). Without writing any proxy config or changing your code, you can redirect, rewrite, block, and delay network requests on the fly.

---

## 🚀 Installation

### Chrome

1. Open `chrome://extensions/`
2. Enable **Developer mode** (top-right toggle)
3. Click **Load unpacked**
4. Select the `dist/chrome` folder

### Firefox

1. Open `about:debugging#/runtime/this-firefox`
2. Click **Load Temporary Add-on**
3. Select `dist/firefox/manifest.json`
   - Or install `dist/requestman-firefox.xpi` directly

---

## 🎯 Quick Start

1. Open any webpage and launch **DevTools** (`F12`)
2. Switch to the **Redirect Rules** tab
3. Click **New Group** → **New Rule**, choose a rule type
4. Fill in the match conditions and the action
5. Make sure the rule, its group, and the **global switch** are all enabled
6. Refresh the page or replay the request to see it take effect

---

## 🛠 Rule Types

### 1. 🔀 Redirect Request

Redirect a request from one URL to another — or to a local file bundled with the extension.

**Use cases:**
- Point production API calls to your local dev server
- Swap a CDN asset for a local build

**Example:**
```
Match URL contains:  api.example.com/v1/users
Redirect to:         http://localhost:3000/v1/users
```

---

### 2. ✏️ Rewrite String

Find and replace a substring inside a request URL.

**Use cases:**
- Switch API versions without changing your source code
- Replace a hostname across all requests

**Example:**
```
Match URL contains:  /api/v1/
Replace:             /api/v1/
With:                /api/v2/
```

---

### 3. 🔗 Query Params

Add, update, or remove URL query parameters.

**Use cases:**
- Append `debug=true` to every API request automatically
- Strip analytics parameters like `utm_source` from outgoing requests
- Override a feature flag: `feature_x=enabled`

**Example:**
```
Match URL contains:  api.example.com
Add param:           debug = true
```

---

### 4. 📤 Modify Request Body

Replace the body of a POST/PUT request — with a static payload or a dynamic JavaScript function.

**Use cases:**
- Hardcode a test payload to reproduce a bug
- Inject extra fields into every form submission

**Static example:**
```json
{ "userId": 42, "role": "admin" }
```

**Dynamic example (JS function):**
```js
function modifyRequestBody(args) {
  const body = JSON.parse(args.body);
  body.debug = true;
  return JSON.stringify(body);
}
```

---

### 5. 📥 Modify Response Body

Replace or transform what the server sends back — with static text or a JavaScript function.

**Use cases:**
- Mock an API endpoint that doesn't exist yet
- Force an error state to test your UI's error handling
- Override a config value returned from the server

**Static example:**
```json
{ "status": "ok", "items": [] }
```

**Dynamic example (JS function):**
```js
function modifyResponse(args) {
  const data = JSON.parse(args.body);
  data.items = [{ id: 1, name: "Mock Item" }];
  return JSON.stringify(data);
}
```

---

### 6. 📋 Modify Headers

Add, update, or delete request or response headers.

**Use cases:**
- Inject an `Authorization` token without changing your app code
- Add `Access-Control-Allow-Origin: *` to bypass CORS during development
- Remove a header that interferes with your debugging

**Example:**
```
Add request header:   Authorization = Bearer my-dev-token
Add response header:  Access-Control-Allow-Origin = *
```

---

### 7. 📱 User Agent

Override the browser's User-Agent string — using a device preset, browser preset, or a custom value.

**Use cases:**
- Test mobile layouts without DevTools emulation
- Simulate a different browser to check compatibility
- Access APIs that behave differently based on client type

**Example:**
```
Preset: iPhone 15  →  Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 ...) AppleWebKit/...
```

---

### 8. 🚫 Cancel Request

Block a request entirely so it never reaches the server.

**Use cases:**
- Silence noisy analytics or tracking calls during debugging
- Block ads or third-party scripts to isolate a performance issue
- Simulate a network failure for a specific endpoint

**Example:**
```
Match URL contains:  analytics.example.com
Action:              Cancel
```

---

### 9. ⏱ Request Delay

Add an artificial delay (in milliseconds) before a request is sent.

**Use cases:**
- Simulate a slow network to test loading spinners and skeleton screens
- Reproduce race conditions that only appear under latency
- Stress-test timeouts and retry logic

**Example:**
```
Match URL contains:  /api/search
Delay:               2000 ms
```

---

## 🔍 Matching & Filtering

Every rule supports fine-grained conditions so it only fires when you want it to.

| Option | Description |
|---|---|
| **Target** | Match against the full `URL` or just the `HOST` |
| **Method** | `contains` / `equals` / `regex` / `wildcard` |
| **Page domain** | Only apply the rule when requests come from a specific page |
| **Resource type** | Limit to XHR, script, image, stylesheet, etc. |
| **HTTP method** | GET, POST, PUT, DELETE, etc. |
| **Request header** | Match on a header value (`equals` / `not_equals` / `contains`) |

---

## 📦 Import & Export

- **Export** all rules to a JSON file for backup or sharing with teammates
- **Import** a JSON file — duplicate IDs are handled automatically

---

## ⚠️ Notes

- **Regex rules:** Make sure your regular expression is valid before saving.
- **Dynamic body scripts:** The function signature must match exactly:
  - Request body: `function modifyRequestBody(args) { ... }`
  - Response body: `function modifyResponse(args) { ... }`
- **Rule priority:** When multiple rules match the same request, order and rule type determine which takes effect. Drag rules to reorder them.
- **Two engines under the hood:**
  - `declarativeNetRequest` — native browser API, stable and performant (used for redirect, headers, cancel, UA, etc.)
  - Injected scripts — more flexible, used for body rewriting and request delay

---

## 🧑‍💻 Development

```bash
# Install dependencies
npm install

# Watch mode (hot rebuild)
npm run dev

# Build for both Chrome and Firefox
npm run build

# Build separately
npm run build:chrome
npm run build:firefox

# Check internal references
npm run check:references

# Package Firefox .xpi
npm run package:firefox
```

**Build output:**
- `dist/chrome/`
- `dist/firefox/`
- `dist/requestman-firefox.xpi` (after running `package:firefox`)
