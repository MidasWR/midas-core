![License: BSL 1.1](https://img.shields.io/badge/License-BSL%201.1-orange.svg)
![Status](https://img.shields.io/badge/Status-Active-brightgreen)
![Platform](https://img.shields.io/badge/Platform-Kubernetes-blue)
![Made with Love](https://img.shields.io/badge/Built%20for-High%20Load-red)

# ✨ **MidasCore**

```bash
███╗   ███╗██╗██████╗  █████╗ ███████╗ ██████╗ ██████╗ ██████╗ ███████╗
████╗ ████║██║██╔══██╗██╔══██╗██╔════╝██╔════╝██╔══██╗██╔══██╗██╔════╝
██╔████╔██║██║██║  ██║███████║███████╗██║     ██║  ██║██████╔╝█████╗
██║╚██╔╝██║██║██║  ██║██╔══██║╚════██║██║     ██║  ██║██╔══██╗██╔══╝
██║ ╚═╝ ██║██║██████╔╝██║  ██║███████║╚██████╗╚██████╔╝██║  ██║███████╗
╚═╝     ╚═╝╚═╝╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝

                  ✧ ✦ ✧   M I D A S C O R E   ✧ ✦ ✧
                     Built for High Load • Forged in Gold
```



**MidasCore** is a high-performance, self-hosted observability platform designed for modern distributed systems.
It delivers enterprise-grade logging, monitoring, and AI-powered insights — **with zero configuration**.

👉 Official website: **[https://midascore.click](https://midascore.click)**

---

## 🚀 Key Capabilities

### **⚡ Zero-Config Installation**

Instant deployment with a single command.
Configure nothing — MidasCore does all the work.

### **📈 High-Throughput Log Streaming**

Designed for extreme workloads: tens of thousands of events per second.

### **🤖 AI-Powered Insights**

* Automated log summaries
* Anomaly detection
* Natural-language querying
* Context awareness

### **📊 Full Observability Dashboard**

* Real-time logs
* Search & filtering
* Latency & error graphs
* RPS analytics
* User & key management

### **🧩 REST + gRPC**

High-performance ingestion via gRPC, with auto-fallback to REST.

---

## 🏷 Pricing

| Tier                       | Description                          | Price      |
| -------------------------- | ------------------------------------ | ---------- |
| **Community Edition**      | Free, full-featured for personal use | $0         |
| **Throughput Expansion**   | +1,000 RPS                           | **$100**   |
| **Compute Node Expansion** | Add node                             | **$100**   |
| **Enterprise**             | SLA, SSO, extended security          | Contact us |

---

## 📦 Installation

```bash
curl -L https://github.com/MidasWR/midas-core-installer/releases/latest/download/installer \
 -o installer && chmod +x installer && ./installer
```

## 🏭 Production-Grade Ingestion Pipeline

MidasCore provides an end-to-end ingestion flow designed for high-load environments, where stability, resilience, and throughput matter more than your sleep schedule.

### **How Logs Travel Through the System**

```
+--------------------+        gRPC Stream        +------------------+ 
|  Log Agent (Host)  |  ───────────────────────> |   Gateway Node   |
|  Docker Container  |                           | (Ingress Layer)  |
+--------------------+                           +------------------+
         |                                                   |
         | file tailing                                      | async batching
         v                                                   v
+------------------------------------------------+    +-----------------------+
| /var/log, /opt, /home mounts (real filesystem) |    |  Kafka Transport Bus  |
+------------------------------------------------+    +-----------------------+
                                                            |
                                                            | high-throughput pipeline
                                                            v
                                              +------------------------------+
                                              |        ClickHouse DB         |
                                              |  (Real-time log storage)     |
                                              +------------------------------+
```

### Core Guarantees

✔ **Backpressure-safe streams**: the agent never chokes even during traffic spikes.
✔ **Batching + compression**: minimal network overhead with optimized payloads.
✔ **Auto-retry**: the agent seamlessly rebuilds the stream after connection failures.
✔ **Zero configuration**: no YAML files, no rituals, no headaches.


## 🛰 Log Agent Example (Docker)

```bash
docker run -d \
  --name midas-agent \
  -v /var/log:/var/log \
  -v /opt:/opt \
  -v /home:/home \
  -e TARGET_ADDRESS=<IP>:50051 \
  midaswr/log-agent-midascore:latest
```

The agent:

* Streams logs from real host directories
* Automatically discovers new files
* Sends everything to the MidasCore Gateway
* Recovers from network failures
* Operates with **zero manual configuration**


## 🌐 Dashboard Preview

*(Placeholder Photo Of Interface)*

![Dashboard](https://img.shields.io/badge/Screenshot-Coming%20Soon-blue)

---

## 🧭 Roadmap

* [ ] Agent-based distributed ingestion
* [ ] Extended AI inference
* [ ] Cloud hybrid mode
* [ ] Webhook automations
* [ ] Audit & compliance layer

---

## 📄 License

MidasCore is licensed under the **Business Source License 1.1 (BSL)**.
Non-commercial and internal use is permitted.
Commercial use requires a paid license until the Change Date.

See: [LICENSE](./LICENSE.md)


