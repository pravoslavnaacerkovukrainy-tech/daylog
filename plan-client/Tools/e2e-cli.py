#!/usr/bin/env python3
"""Межклиентский прогон через CLI chaos-sync: два клиента (каталоги A и B) против одного сервера.

  python3 -I e2e-cli.py --bin build/plan/chaos-sync --server http://127.0.0.1:3199 [--stub]

Пароль берётся из CHAOS_SYNC_PASSWORD. Данные только синтетические; задачи выбираются из
списка сервера (первые открытые). --stub включает сценарий потерянного ответа через
тестовую ручку временного сервера (у настоящего сервера её нет).
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import tempfile
import urllib.request

FAIL = []


def run(bin_, data, *args, server=None, expect=(0,)):
    cmd = [bin_, "--data", data] + (["--server", server] if server else []) + list(args)
    p = subprocess.run(cmd, capture_output=True, text=True)
    try:
        out = json.loads(p.stdout)
    except ValueError:
        out = {"raw": p.stdout, "stderr": p.stderr}
    if p.returncode not in expect:
        FAIL.append("%s → код %d: %s" % (" ".join(args), p.returncode, p.stdout[-400:]))
    return out, p.returncode


def check(ok, what):
    print(("  ✓ " if ok else "  ✗ ") + what)
    if not ok:
        FAIL.append(what)


def task(out, tid):
    return next((t for t in out.get("tasks", []) if t["id"] == tid), None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--server", required=True)
    ap.add_argument("--stub", action="store_true")
    ap.add_argument("--keep", action="store_true", help="не удалять каталоги A и B")
    a = ap.parse_args()
    if not os.environ.get("CHAOS_SYNC_PASSWORD"):
        sys.exit("Задайте CHAOS_SYNC_PASSWORD")
    root = tempfile.mkdtemp(prefix="plan-e2e-")
    A, B = os.path.join(root, "A"), os.path.join(root, "B")
    print("Каталоги клиентов:", A, B)

    print("• получение задач двумя клиентами")
    outA, _ = run(a.bin, A, "pull", server=a.server)
    outB, _ = run(a.bin, B, "pull", server=a.server)
    open_ = [t for t in outA.get("tasks", []) if not t["is_completed"] and not t["is_removed"]]
    check(len(open_) >= 3, "есть хотя бы три открытые задачи")
    if len(open_) < 3:
        return finish(root, a.keep)
    t1, t2, t3 = open_[0]["id"], open_[1]["id"], open_[2]["id"]
    check(task(outB, t1) is not None, "клиент B видит те же задачи")
    base = datetime.date(2026, 11, 20)
    d = lambda n: (base + datetime.timedelta(days=n)).isoformat()

    print("• офлайн-правка дня, перезапуск, отправка")
    run(a.bin, A, "offline", "on")
    out, _ = run(a.bin, A, "edit", t1, "--day", d(0))
    check(out["status"]["queued"] == 1, "правка в очереди A")
    out, code = run(a.bin, A, "push", expect=(0, 1))
    check(out["report"]["applied"] == [] and out["status"]["connection"]["state"] == "offline_manual", "в офлайне ничего не ушло")
    out, _ = run(a.bin, A, "status")  # новый процесс = перезапуск ядра
    check(out["status"]["queued"] == 1 and out["status"]["offline"], "после перезапуска очередь и офлайн на месте")
    run(a.bin, A, "offline", "off")
    out, _ = run(a.bin, A, "push")
    check(out["report"]["applied"] == [t1] and out["status"]["queued"] == 0, "очередь A отправлена")
    out, _ = run(a.bin, A, "push")
    check(out["report"]["applied"] == [], "повторная отправка ничего не дублирует")
    out, _ = run(a.bin, B, "pull")
    check(task(out, t1)["day"] == d(0), "клиент B видит новый день")

    print("• разные поля одной задачи с двух клиентов")
    run(a.bin, A, "edit", t2, "--text", "Синтетика: текст с A")
    run(a.bin, B, "edit", t2, "--details", "подробности с B")
    run(a.bin, A, "push")
    out, _ = run(a.bin, B, "push")
    check(out["report"]["applied"] == [t2] and not out["report"]["conflicts"], "без конфликта")
    out, _ = run(a.bin, A, "pull")
    t = task(out, t2)
    check(t["text"] == "Синтетика: текст с A" and t["details"] == "подробности с B", "на сервере оба поля")

    print("• конфликт одного поля: «Моя версия»")
    run(a.bin, B, "pull")
    run(a.bin, A, "edit", t3, "--day", d(1))
    run(a.bin, B, "edit", t3, "--day", d(2))
    run(a.bin, A, "push")
    out, code = run(a.bin, B, "push", expect=(3,))
    pe = next((p for p in out["status"]["pending"] if p["task_id"] == t3), {})
    check(code == 3 and pe.get("status") == "conflict" and pe.get("conflict_fields") == ["day"], "конфликт по day, код 3")
    check(pe.get("changes", {}).get("day") == d(2) and pe.get("server_task", {}).get("day") == d(1), "видны обе версии")
    run(a.bin, B, "resolve", t3, "day", "mine")
    out, _ = run(a.bin, B, "push")
    check(out["report"]["applied"] == [t3], "«Моя версия» отправлена")
    out, _ = run(a.bin, A, "pull")
    check(task(out, t3)["day"] == d(2), "на сервере версия B")

    print("• конфликт одного поля: «Версия сервера»")
    run(a.bin, A, "edit", t3, "--day", d(3))
    run(a.bin, B, "edit", t3, "--day", d(4))
    run(a.bin, A, "push")
    run(a.bin, B, "push", expect=(3,))
    out, _ = run(a.bin, B, "resolve", t3, "day", "server")
    check(out["status"]["pending"] == [], "правка B убрана")
    out, _ = run(a.bin, B, "list")
    check(task(out, t3)["day"] == d(3), "B показывает версию сервера")

    if a.stub:
        print("• потерянный ответ (временный сервер)")
        rev = lambda: json.load(urllib.request.urlopen(a.server + "/__test/revision/" + t1))["revision"]
        before = rev()
        req = urllib.request.Request(a.server + "/__test/drop-next", data=b"{}", headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req).read()
        run(a.bin, A, "edit", t1, "--day", d(5))
        out, code = run(a.bin, A, "push", expect=(1,))
        pe = out["status"]["pending"][0] if out["status"]["pending"] else {}
        check(pe.get("uncertain") is True, "запрос помечен как неподтверждённый")
        out, _ = run(a.bin, A, "push")
        check(out["report"]["applied"] == [t1] and out["status"]["queued"] == 0, "повтор подтверждён")
        check(rev() == before + 1, "ревизия выросла ровно на одну")

    return finish(root, a.keep)


def finish(root, keep):
    if not keep:
        import shutil
        shutil.rmtree(root, ignore_errors=True)
    print("ошибок:", len(FAIL))
    for f in FAIL:
        print("  -", f)
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
