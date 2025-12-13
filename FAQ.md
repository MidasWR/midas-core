
## 1. I lost my admin password. What should I do?

During installation, the installer prints the first admin credentials, for example:

```text
[INFO] ✔ Installation finished.

[INFO] Grafana:     http://<YOUR_SERVER_IP>:32000   (admin / prom-operator)
[INFO] Frontend:    http://<YOUR_SERVER_IP>:30070

[INFO] First admin user (API):
{
  "Login": "admin@midascore.local",
  "password": "KVC<bYvuB]f({BBz"
}

[SUCCESS] Result saved into file: admin_info.json
MidasCore is ready. Time to bend the logs to your will.
````

If you closed the terminal and forgot the password, you can usually recover it from the generated file:

```bash
sudo find / -maxdepth 4 -type f -name "admin_info.json" 2>/dev/null
```

On a typical install you’ll see something like:

```text
/tmp/midas-install-XXXXXXX/admin_info.json
```

Then just open the file:

```bash
cd /tmp/midas-install-XXXXXXX/
cat admin_info.json
```

Inside you’ll find the same JSON with `Login` and `password` for the first admin user.

## 2. How does the billing plan work?

The billing model is based on two main limits:

* **RPS (requests per second)**: how many log events you’re allowed to send per second.
* **Number of connected servers (agents)**: how many agents can be actively pushing logs.

If you stay within your plan, all logs are accepted.
If you exceed the limits, the internal **cutter** mechanism starts dropping excess traffic so the platform stays healthy.

## 3. I don’t understand how to filter logs in the UI

Filtering is designed to be as lazy as possible:

1. Open any log entry in the UI.
2. Click on the field you’re interested in (e.g. `service`, `env`, `trace_id`).
3. The UI will automatically create a filter by that field and reload the results.

You don’t have to manually type query syntax unless you want something more advanced.

## 4. How do I add a new server (agent)?

1. Make sure your current plan allows another server.
   If not, upgrade your plan first.
2. Go to the **Plan** (or **Billing / Plan**) section in the MidasCore frontend.
3. Click **New Agent**.
4. Copy the generated command/token and run it on the new server
   (usually it’s a `docker run ...` command for `midas-agent`).

After that, the agent will register itself and start streaming logs to your cluster.

## 5. What happens if I send more logs than my subscription limit?

Nothing dramatic, just wasteful.

When you exceed your allowed RPS or node limits:

* The **cutter** component starts ignoring part of incoming logs.
* Only the amount that fits into your plan is processed and stored.
* Extra logs are silently dropped instead of overloading the system.

If you don’t like losing logs, upgrade the plan or reduce noise on the client side.

## 6. Where can I see metrics and dashboards?

MidasCore deploys observability components together with the stack.

By default:

* **Grafana**:
  `http://<YOUR_SERVER_IP>:32000`
  Login: `admin`
  Password: `prom-operator`

* **Frontend (MidasCore UI)**:
  `http://<YOUR_SERVER_IP>:30070`

Grafana already has dashboards for system metrics, RPS, agents, and other internals of the platform.

```

