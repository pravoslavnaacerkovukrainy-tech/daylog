#!/usr/bin/env python3
"""Временный локальный сервер протокола синхронизации для проверки клиента.

Только loopback, только синтетические данные в памяти. Не замена настоящему серверу:
приёмка межклиентского обмена должна идти против него. Реализует:
  POST /api/auth/login, GET /api/tasks, GET /api/tasks/:id, POST /api/sync/tasks/:id,
  GET/POST /api/chaos, POST /api/chaos/:id/to-task|to-note, POST /api/tasks/:id/complete|reopen.
Тестовые ручки (без входа): POST /__test/edit {id, field, value} — правка «с другого клиента»,
POST /__test/drop-next — применить следующий sync, но оборвать ответ, GET /__test/revision/:id.

Запуск: python3 -I stub-server.py --port 3199 --password synthetic-pass
"""
import argparse
import json
import re
import secrets
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TASKS = {}
ORDER = []
CHAOS = []
SESSIONS = set()
STATE = {"drop_next": False, "password": "synthetic-pass", "now": 0}


def stamp():
    STATE["now"] += 1
    return "2026-11-13T12:%02d:%02dZ" % (STATE["now"] // 60 % 60, STATE["now"] % 60)


def add_task(tid, text, day="", details=None, completed=False, removed=False):
    tid = tid.lower()
    TASKS[tid] = {
        "id": tid, "text": text, "day": day, "deadline": None, "review_date": None, "area": "work",
        "project_id": None, "status": "removed" if removed else "ready", "waiting_for": None,
        "promised_to": None, "at_risk": False, "removal_reason": "синтетика" if removed else None,
        "details": details, "steps": [], "completed_at": "2026-11-12T10:00:00Z" if completed else None,
        "entry_id": None, "created_at": "2026-11-10T09:00:00Z", "updated_at": stamp(),
        "is_completed": completed, "is_removed": removed, "is_open": not completed and not removed,
        "next_step": None, "_rev": 1,
    }
    ORDER.append(tid)


def public(t):
    return {k: v for k, v in t.items() if not k.startswith("_")}


def seed():
    add_task("11111111-1111-4111-8111-000000000001", "Синтетика: подготовить отчёт", "2026-11-13", "Черновик в общей папке")
    add_task("11111111-1111-4111-8111-000000000002", "Синтетика: позвонить в сервис", "2026-11-14")
    add_task("11111111-1111-4111-8111-000000000003", "Синтетика: купить батарейки", "")
    add_task("11111111-1111-4111-8111-000000000004", "Синтетика: проверить расписание", "2026-11-16", None)
    add_task("11111111-1111-4111-8111-000000000005", "Синтетика: отправить письмо", "2026-11-12", None, completed=True)
    add_task("11111111-1111-4111-8111-000000000006", "Синтетика: старая идея", "", None, removed=True)
    CHAOS.append({"id": "22222222-2222-4222-8222-000000000001", "text": "Синтетика: уточнить адрес",
                  "urgent": True, "created_at": "2026-11-13T08:00:00Z"})


def normalize(field, value):
    if field == "day":
        if not isinstance(value, str):
            raise ValueError("day: ожидается строка")
        v = value.strip()
        if v and not DAY_RE.match(v):
            raise ValueError("day: нужна дата ГГГГ-ММ-ДД")
        return v
    if field == "text":
        if not isinstance(value, str) or not value.strip():
            raise ValueError("Название не может быть пустым.")
        return value.strip()
    if field == "details":
        if value is None:
            return None
        if not isinstance(value, str):
            raise ValueError("details: строка или null")
        return value.strip() or None
    raise ValueError("Поле %s не поддерживается." % field)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send(self, status, obj, headers=None):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def ok(self, data, status=200, headers=None):
        self.send(status, {"ok": True, "data": data}, headers)

    def err(self, status, code, message, data=None):
        obj = {"error": {"code": code, "message": message}}
        if data is not None:
            obj["data"] = data
        self.send(status, obj)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            obj = json.loads(raw or b"{}")
        except ValueError:
            return None
        return obj if isinstance(obj, dict) else None

    def authed(self):
        cookie = self.headers.get("Cookie") or ""
        for part in cookie.split(";"):
            k, _, v = part.strip().partition("=")
            if k == "chaos_day_session" and v in SESSIONS:
                return True
        return False

    def do_GET(self):
        path = self.path.split("?")[0]
        if path.startswith("/__test/revision/"):
            t = TASKS.get(path.rsplit("/", 1)[1].lower())
            return self.send(200, {"revision": t["_rev"] if t else None})
        if not self.authed():
            return self.err(401, "unauthorized", "Нужно войти.")
        if path == "/api/tasks":
            return self.ok({"tasks": [public(TASKS[i]) for i in ORDER if i in TASKS]})
        m = re.match(r"^/api/tasks/([^/]+)$", path)
        if m:
            t = TASKS.get(m.group(1).lower())
            return self.ok({"task": public(t)}) if t else self.err(404, "not_found", "Задача не найдена.")
        if path == "/api/chaos":
            return self.ok({"chaos": CHAOS})
        return self.err(404, "not_found", "Такого пути API нет.")

    def do_POST(self):
        path = self.path.split("?")[0]
        if not (self.headers.get("Content-Type") or "").startswith("application/json"):
            return self.err(415, "unsupported_media_type", "Изменяющие запросы принимаются только в JSON.")
        body = self.body()
        if body is None:
            return self.err(400, "invalid_request", "Ожидался JSON-объект.")
        if path == "/__test/edit":
            t = TASKS.get(str(body.get("id", "")).lower())
            if not t:
                return self.err(404, "not_found", "Задача не найдена.")
            t[body["field"]] = normalize(body["field"], body.get("value"))
            t["_rev"] += 1
            t["updated_at"] = stamp()
            return self.ok({"task": public(t)})
        if path == "/__test/drop-next":
            STATE["drop_next"] = True
            return self.ok({})
        if path == "/__test/delete":
            TASKS.pop(str(body.get("id", "")).lower(), None)
            return self.ok({})
        if path == "/api/auth/login":
            if body.get("password") != STATE["password"]:
                return self.err(401, "unauthorized", "Неверный пароль.")
            token = secrets.token_hex(16)
            SESSIONS.add(token)
            return self.send(200, {"ok": True, "authenticated": True}, {
                "Set-Cookie": "chaos_day_session=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=3600" % token})
        if not self.authed():
            return self.err(401, "unauthorized", "Нужно войти.")
        m = re.match(r"^/api/sync/tasks/([^/]+)$", path)
        if m:
            return self.sync(m.group(1).lower(), body)
        if path == "/api/chaos":
            text = str(body.get("text") or "").strip()
            if not text:
                return self.err(400, "empty_text", "Запись пустая.")
            item = {"id": str(uuid.uuid4()), "text": text, "urgent": bool(body.get("urgent")), "created_at": stamp()}
            CHAOS.append(item)
            return self.ok({"chaos": item}, 201)
        m = re.match(r"^/api/chaos/([^/]+)/(to-task|to-note)$", path)
        if m:
            cid = m.group(1).lower()
            item = next((c for c in CHAOS if c["id"] == cid), None)
            if not item:
                return self.err(404, "not_found", "Строка не найдена.")
            CHAOS.remove(item)
            if m.group(2) == "to-note":
                return self.ok({"note": {"id": str(uuid.uuid4()), "title": item["text"]}, "removed_chaos_id": cid}, 201)
            tid = str(uuid.uuid4())
            add_task(tid, normalize("text", body.get("text") or item["text"]), normalize("day", body.get("day") or ""))
            return self.ok({"task": public(TASKS[tid]), "removed_chaos_id": cid}, 201)
        m = re.match(r"^/api/tasks/([^/]+)/(complete|reopen)$", path)
        if m:
            t = TASKS.get(m.group(1).lower())
            if not t:
                return self.err(404, "not_found", "Задача не найдена.")
            done = m.group(2) == "complete"
            t.update(is_completed=done, completed_at=stamp() if done else None, is_open=not done and not t["is_removed"])
            t["_rev"] += 1
            return self.ok({"task": public(t), "entry": None})
        return self.err(404, "not_found", "Такого пути API нет.")

    def sync(self, tid, body):
        base, changes = body.get("base"), body.get("changes")
        if not isinstance(base, dict) or not isinstance(changes, dict) or not changes or set(base) != set(changes):
            return self.err(400, "invalid_request", "base и changes должны содержать одинаковый непустой набор полей.")
        t = TASKS.get(tid)
        if not t:
            return self.err(404, "not_found", "Задача не найдена.")
        apply, conflicts = {}, []
        try:
            for f in sorted(changes):
                new = normalize(f, changes[f])
                old = normalize(f, base[f]) if f != "text" else str(base[f]).strip()
                cur = t[f]
                if cur == new:
                    continue
                if cur == old:
                    apply[f] = new
                else:
                    conflicts.append(f)
        except ValueError as e:
            return self.err(400, "invalid_request", str(e))
        if conflicts:
            return self.err(409, "sync_conflict", "Задачу изменили на сервере.", {"task": public(t), "conflicts": conflicts})
        if apply:
            t.update(apply)
            t["_rev"] += 1
            t["updated_at"] = stamp()
        if STATE["drop_next"]:
            STATE["drop_next"] = False
            self.close_connection = True
            self.connection.close()
            return
        return self.ok({"task": public(t)})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=3199)
    ap.add_argument("--password", default="synthetic-pass")
    a = ap.parse_args()
    STATE["password"] = a.password
    seed()
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print("stub sync server on http://127.0.0.1:%d" % a.port, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
