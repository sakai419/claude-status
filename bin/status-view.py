#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""~/.claude/status/status.md を端末サイズに追従して表示するビューア。

一覧（既定）
- 行を端末幅（表示セル数、全角=2）で切り詰めるので折り返しが起きない
- ANSI エスケープ（色・太字）は幅0として扱い、切り詰め時は末尾に reset を足す
- 曖昧幅（─ や ▌ など East Asian Ambiguous）が1セルか2セルかは起動時に端末へ実測
- 端末の自動折り返し自体も無効化して、幅計算が外れても崩れないようにする
- SIGWINCH を受けたら即座に再描画。内容・サイズが変わった時だけ描くのでちらつかない
- ↑↓ / j k でセッションを選択（選択中は左端に反転バーが出る）

詳細（Enter）
- 一覧では短縮しているプロンプトの全文と、エージェントの返答を読む
- 返答は transcript（~/.claude/projects/<slug>/<session_id>.jsonl）の
  「最後のユーザー発話より後ろの assistant テキスト」を拾う
- 実行中・質問中のセッションでは、その時点までの途中の返答が出る

一覧から消す（x）
- 選択中のセッションの JSON を消して一覧から外す（y で確定、他のキーで取り消し）
- Desktop 起動のセッションには CLI の exit に相当する操作が無く、閉じるまでプロセスが
  生き続けて PID ベースの reap では消えないため、その手動版として用意している
- プロセスは殺さない。消した後もそのセッションが動けば、次の hook でまた現れる

キー: ↑↓/jk 移動 · Enter 詳細/戻る · Space/b ページ · x 一覧から消す · Esc 戻る（一覧では終了） · q 終了

セッションの一覧と表示順は claude-status-render.sh が書く status.index.json から取る。
「status.md の N 番目のブロック＝索引の N 番目」という対応で突き合わせる。

システム標準の python3 で動くよう、標準ライブラリのみを使う。
"""

import glob
import json
import os
import re
import select
import signal
import subprocess
import sys
import termios
import time
import tty
import unicodedata

ROOT = os.path.expanduser(os.environ.get("CS_STATUS_ROOT", "~/.claude/status"))
PATH = os.path.expanduser(os.environ.get("CS_STATUS_FILE", os.path.join(ROOT, "status.md")))
INDEX_PATH = os.path.join(ROOT, "status.index.json")
SESSIONS = os.path.join(ROOT, "sessions")
RENDER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "claude-status-render.sh")
PROJECTS = os.path.expanduser("~/.claude/projects")
INTERVAL = float(os.environ.get("CS_INTERVAL", "2"))
NO_COLOR = bool(os.environ.get("NO_COLOR"))

ALT_ON, ALT_OFF = "\x1b[?1049h", "\x1b[?1049l"
CUR_HIDE, CUR_SHOW = "\x1b[?25l", "\x1b[?25h"
WRAP_OFF, WRAP_ON = "\x1b[?7l", "\x1b[?7h"
HOME, EL, ED = "\x1b[H", "\x1b[K", "\x1b[J"
RESET, BOLD, DIM, REVERSE = "\x1b[0m", "\x1b[1m", "\x1b[2m", "\x1b[7m"

SGR_RE = re.compile(r"\x1b\[[0-9;]*m")
INDENT_RE = re.compile(r"((?:\x1b\[[0-9;]*m)*)(\s*)")
# claude-status-render.sh が書くセッションブロックの行（先頭2スペース＋色付きの ▌）
BLOCK_RE = re.compile(r"^  \x1b\[[0-9;]*m▌")
# 選択中の行頭。反転スペース＋スペースで元のインデント（2セル）と同じ幅にする
SELECTED = REVERSE + " " + RESET + " "

PINNED = 2  # status.md の先頭2行（見出しと区切り線）はスクロールさせない

STATUS_LOOK = {
    "waiting":   ("⚠️", "質問中", "33"),
    "subagent":  ("🟣", "サブ待ち", "35"),
    "completed": ("✅", "完了", "32"),
    "running":   ("🔵", "実行中", "36"),
}
# アイドルは状態そのものではなく「更新が止まっている」という表示上の降格。
# 元の状態は claude-status-render.sh と同じく添えて出す。
IDLE_LOOK = ("💤", "アイドル", "90")

# 曖昧幅の文字を何セルで描くか。起動時に端末へ実測して上書きする。
# 実測できない環境では従来の想定値 2 を使う。
AMBIG = 2


def is_control(ch):
    """端末を操作しうる制御文字か（C0・DEL・C1）。表示する文字列からは落とす。"""
    o = ord(ch)
    return o < 0x20 or 0x7F <= o <= 0x9F


def plain_text(text):
    """色指定を外し、残りの制御文字も落とす（改行は残す）。非TTY出力用。"""
    text = SGR_RE.sub("", text)
    return "".join(ch for ch in text if ch == "\n" or not is_control(ch))


def cell_width(ch):
    if unicodedata.combining(ch):
        return 0
    eaw = unicodedata.east_asian_width(ch)
    if eaw in ("W", "F"):
        return 2
    if eaw == "A":
        return AMBIG
    return 1


def text_width(s):
    return sum(cell_width(ch) for ch in SGR_RE.sub("", s))


def probe_ambiguous_width(fd, out, rows):
    """曖昧幅の文字を端末が1セルで描くか2セルで描くかを問い合わせる。

    最下行の先頭に ─ を1つ描き、カーソル位置報告（CPR）で返る桁から逆算する。
    描いた文字はすぐ消すので画面には残らない。CPR に応答しない端末では None。
    """
    try:
        out.write("\x1b[%d;1H─\x1b[6n" % rows)
        out.flush()
        buf = b""
        deadline = time.monotonic() + 0.25
        while True:
            timeout = deadline - time.monotonic()
            if timeout <= 0:
                break
            ready, _, _ = select.select([fd], [], [], timeout)
            if not ready:
                break
            chunk = os.read(fd, 64)
            if not chunk:
                break
            buf += chunk
            if b"R" in buf:
                break
        out.write("\x1b[%d;1H%s" % (rows, EL))
        out.flush()
        while True:  # 取り残した応答バイトを掃き出す
            ready, _, _ = select.select([fd], [], [], 0.02)
            if not ready:
                break
            if not os.read(fd, 64):
                break
        m = re.search(rb"\[\d+;(\d+)R", buf)
        if m:
            col = int(m.group(1))
            if col in (2, 3):
                return col - 1
    except Exception:
        pass
    return None


def fit(line, width):
    """line を width セル以内に収める。溢れる場合は末尾を … にする。"""
    line = line.replace("\t", "    ").rstrip("\n")
    if NO_COLOR:
        line = SGR_RE.sub("", line)

    plain = SGR_RE.sub("", line)
    stripped = plain.lstrip(" ")
    # 区切り線は幅いっぱいに引き直す（元の固定長だと端末幅と合わない）
    if stripped and set(stripped) == {"─"}:
        m = INDENT_RE.match(line)
        codes, indent = (m.group(1), m.group(2)) if m else ("", "")
        unit = cell_width("─") or 1
        count = max(0, (width - len(indent)) // unit)
        return codes + indent + "─" * count + (RESET if codes else "")

    out, w, has_sgr = [], 0, False
    i, n = 0, len(line)
    while i < n:
        ch = line[i]
        if ch == "\x1b":
            m = SGR_RE.match(line, i)
            if m:  # 色指定は幅0でそのまま通す
                out.append(m.group(0))
                has_sgr = True
                i = m.end()
            else:  # 未対応のエスケープは落とす
                i += 1
            continue
        i += 1
        if is_control(ch):  # 制御文字は落とす
            continue
        cw = cell_width(ch)
        if w + cw > width:
            # … は曖昧幅なので 2 セル分を確保しておく（環境差で溢れないように）
            while out and w + 2 > width:
                tok = out.pop()
                if not tok.startswith("\x1b"):
                    w -= cell_width(tok)
            out.append("…")
            break
        out.append(ch)
        w += cw
    body = "".join(out)
    if has_sgr and not body.endswith(RESET):
        body += RESET
    return body


def wrap(text, width, indent=""):
    """text を width セル以内の行に折り返す。日本語のために任意位置で折る。

    色指定（SGR）は幅0のまま持ち越す。切り詰めではなく折り返しなので、
    詳細ペインでは長文がすべて読める。
    """
    lines = []
    for para in (text or "").replace("\t", "    ").split("\n"):
        if not SGR_RE.sub("", para).strip():
            lines.append("")
            continue
        cur, w, visible = [indent], text_width(indent), 0
        i, n = 0, len(para)
        while i < n:
            m = SGR_RE.match(para, i)
            if m:
                cur.append(m.group(0))
                i = m.end()
                continue
            ch = para[i]
            i += 1
            if is_control(ch):
                continue
            cw = cell_width(ch)
            if w + cw > width and visible:
                lines.append("".join(cur))
                cur, w, visible = [indent], text_width(indent), 0
            cur.append(ch)
            w += cw
            visible += 1
        lines.append("".join(cur))
    return lines


def read_lines():
    try:
        with open(PATH, encoding="utf-8", errors="replace") as fh:
            return fh.read().splitlines()
    except FileNotFoundError:
        return ["(ステータスファイルがありません: %s)" % PATH]
    except OSError as exc:
        return ["(読み込みエラー: %s)" % exc]


def read_index():
    """表示順のセッション索引。読めなければ空（選択機能を諦めて一覧だけ出す）。"""
    try:
        with open(INDEX_PATH, encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def block_ranges(lines):
    """セッションブロック（連続する ▌ 行）の [開始, 終了] を表示順に返す。"""
    ranges, start = [], None
    for i, line in enumerate(lines):
        if BLOCK_RE.match(line):
            if start is None:
                start = i
        elif start is not None:
            ranges.append((start, i - 1))
            start = None
    if start is not None:
        ranges.append((start, len(lines) - 1))
    return ranges


def transcript_path(entry):
    """transcript の実ファイル。hook が記録した値を優先し、無ければ id で探す。"""
    path = entry.get("transcript_path") or ""
    if path and os.path.exists(path):
        return path
    sid = entry.get("session_id") or ""
    if not sid:
        return ""
    found = glob.glob(os.path.join(PROJECTS, "*", sid + ".jsonl"))
    return found[0] if found else ""


def _entry_text(obj):
    message = obj.get("message") or {}
    content = message.get("content")
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts = [
            b.get("text") or ""
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        ]
        return "\n".join(p for p in parts if p.strip()).strip()
    return ""


def read_reply(path):
    """最後のユーザー発話より後ろの assistant テキストを、出た順に返す。

    ツール呼び出しやサブエージェント（isSidechain）は読み飛ばす。末尾から
    走査して最後のユーザー発話に当たったところで止めるので、長い transcript
    でも解析するのは末尾だけで済む。
    """
    # 長時間セッションの transcript は数MBになるので末尾だけ読む。
    # 途中で切れた先頭行は JSON として捨てられるので害はない。
    tail_bytes = 4 * 1024 * 1024
    try:
        with open(path, "rb") as fh:
            size = os.fstat(fh.fileno()).st_size
            if size > tail_bytes:
                fh.seek(size - tail_bytes)
            raw_lines = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return []

    replies = []
    for raw in reversed(raw_lines):
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except Exception:
            continue
        if obj.get("isSidechain") or obj.get("isMeta"):
            continue
        kind = obj.get("type")
        if kind not in ("user", "assistant"):
            continue
        text = _entry_text(obj)
        if not text:
            continue
        if kind == "user":
            break
        replies.append(text)
        if len(replies) >= 30:
            break
    replies.reverse()
    return replies


_reply_cache = {}


def reply_cached(path):
    """(mtime, size) が変わらない間は解析結果を使い回す。"""
    try:
        st = os.stat(path)
        key = (path, st.st_mtime_ns, st.st_size)
    except OSError:
        return []
    if _reply_cache.get("key") == key:
        return _reply_cache.get("value", [])
    value = read_reply(path)
    _reply_cache["key"] = key
    _reply_cache["value"] = value
    return value


def dismiss(session_id):
    """セッションを一覧から取り除く（JSON を消して status.md を再生成する）。
    プロセスは殺さないので、そのセッションがまた動けば次の hook で戻ってくる。"""
    sid = os.path.basename(session_id or "")
    if not sid:
        return
    try:
        os.remove(os.path.join(SESSIONS, sid + ".json"))
    except OSError:
        return
    try:
        subprocess.run([RENDER], timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def rel_time(epoch, now):
    d = int(now - (epoch or 0))
    if d < 0:
        return "未来"
    if d < 60:
        return "%d秒前" % d
    if d < 3600:
        return "%d分前" % (d // 60)
    if d < 86400:
        return "%d時間前" % (d // 3600)
    return "%d日前" % (d // 86400)


def detail_body(entry, width):
    """詳細ペインの本文。折り返し済みの行リストを返す。"""
    status = entry.get("status") or ""
    icon, label, color = STATUS_LOOK.get(status, ("❔", status or "不明", "35"))
    if entry.get("idle"):
        icon, label, color = IDLE_LOOK[0], "%s（%s）" % (IDLE_LOOK[1], label), IDLE_LOOK[2]
    head = "\x1b[1;%sm" % color

    cwd = entry.get("cwd") or ""
    home = os.path.expanduser("~")
    shown = ("~" + cwd[len(home):]) if cwd.startswith(home) else cwd
    parts = shown.split("/")
    proj = parts[-1] if parts else shown
    prefix = "/".join(parts[:-1]) + "/" if len(parts) > 1 else ""

    out = []
    out.append("%s%s %s%s  %s%s%s%s%s%s" % (
        head, icon, label, RESET, DIM, prefix, RESET, BOLD, proj, RESET))
    out.append(DIM + " ─────────" + RESET)
    out.append("")
    out.append("%s 更新%s %s %s(%s)%s" % (
        DIM, RESET, entry.get("updated_at") or "-",
        DIM, rel_time(entry.get("updated_epoch"), time.time()), RESET))
    if entry.get("intent"):
        out.extend(wrap("%s 意図%s %s" % (DIM, RESET, entry["intent"]), width))
    if status == "subagent" and entry.get("subagent_count"):
        types = entry.get("subagent_types") or ""
        line = "%s サブ%s %d件" % (DIM, RESET, entry["subagent_count"])
        if types:
            line += " %s%s%s" % (DIM, types, RESET)
        out.extend(wrap(line, width))
    out.append("")

    out.append("%s プロンプト%s" % (head, RESET))
    prompt = entry.get("last_prompt") or ""
    if prompt.strip():
        out.extend(wrap(prompt, width - 2, "  "))
    else:
        out.append("  " + DIM + "(記録がありません)" + RESET)
    out.append("")

    path = transcript_path(entry)
    replies = reply_cached(path) if path else []
    note = "" if status == "completed" else "  %s(進行中)%s" % (DIM, RESET)
    out.append("%s 返答%s%s" % (head, RESET, note))
    if replies:
        for i, text in enumerate(replies):
            if i:
                out.append("")
            out.extend(wrap(text, width - 2, "  "))
    elif not path:
        out.append("  " + DIM + "(transcript が見つかりません)" + RESET)
    else:
        out.append("  " + DIM + "(まだ返答がありません)" + RESET)
    return out


def footer(mode, cols, sel, total, pending=False):
    if pending:
        # 確認中は他のキーヒントを出さず、y/n だけに絞る
        return fit("\x1b[1;33m このセッションを一覧から消す? \x1b[0m"
                   + DIM + "y 消す · 他のキー 取り消し" + RESET, cols)
    if mode == "detail":
        hint = " ↑↓/jk スクロール · Space/b ページ · g/G 先頭/末尾 · Esc 一覧へ · q 終了"
    elif total:
        hint = " ↑↓/jk 選択 (%d/%d) · Enter 詳細 · x 消す · q 終了" % (sel + 1, total)
    else:
        hint = " q 終了"
    return fit(DIM + hint + RESET, cols)


def window(body, avail, keep_start=None, keep_end=None):
    """body から avail 行だけ切り出す。keep_* が指定されればそれを含む位置にずらす。"""
    if avail <= 0:
        return []
    if len(body) <= avail:
        return body
    off = 0
    if keep_start is not None:
        off = min(keep_start, max(0, (keep_end or keep_start) - avail + 1))
    off = max(0, min(off, len(body) - avail))
    return body[off:off + avail]


def build_list(lines, ranges, sel, cols, rows, pending=False):
    marked = list(lines)
    if sel is not None and sel < len(ranges):
        start, end = ranges[sel]
        for i in range(start, min(end, len(marked) - 1) + 1):
            if marked[i].startswith("  "):
                marked[i] = SELECTED + marked[i][2:]

    head = [fit(l, cols) for l in marked[:PINNED]]
    rest = marked[PINNED:]
    avail = max(0, rows - len(head) - 1)  # 最下行はフッタ
    keep_start = keep_end = None
    if sel is not None and sel < len(ranges):
        keep_start = max(0, ranges[sel][0] - PINNED)
        keep_end = max(0, ranges[sel][1] - PINNED)
    body = [fit(l, cols) for l in window(rest, avail, keep_start, keep_end)]
    body += [""] * max(0, avail - len(body))
    return head + body + [footer("list", cols, sel or 0, len(ranges), pending)]


def build_detail(entry, scroll, cols, rows):
    body = detail_body(entry, cols - 1)
    avail = max(1, rows - 1)
    scroll = max(0, min(scroll, max(0, len(body) - avail)))
    lines = [fit(l, cols) for l in body[scroll:scroll + avail]]
    lines += [""] * max(0, avail - len(lines))
    return lines + [footer("detail", cols, 0, 0)], scroll


def read_key(fd):
    """1キー分を読む。矢印キーは b"UP" / b"DOWN" に正規化する。"""
    key = os.read(fd, 1)
    if key != b"\x1b":
        return key
    # 端末からの応答や矢印キーは ESC の後に続きがある。素の Esc は続きが無い。
    more, _, _ = select.select([fd], [], [], 0.05)
    if not more:
        return b"\x1b"
    try:
        seq = os.read(fd, 32)
    except BlockingIOError:
        return b"\x1b"
    if seq.endswith(b"A"):
        return b"UP"
    if seq.endswith(b"B"):
        return b"DOWN"
    return b"SEQ"


def main():
    global AMBIG

    if not sys.stdout.isatty():
        sys.stdout.write(plain_text("\n".join(read_lines())) + "\n")
        return 0

    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd) if sys.stdin.isatty() else None

    # SIGWINCH で select を即座に起こすための自己パイプ
    rpipe, wpipe = os.pipe()
    os.set_blocking(wpipe, False)
    os.set_blocking(rpipe, False)
    signal.set_wakeup_fd(wpipe)
    signal.signal(signal.SIGWINCH, lambda *_: None)

    out = sys.stdout
    out.write(ALT_ON + CUR_HIDE + WRAP_OFF)
    out.flush()

    mode, sel_id, scroll = "list", None, 0
    pending = False   # x を押した後の削除確認待ち
    prev = None
    try:
        if saved is not None:
            tty.setcbreak(fd)
            measured = probe_ambiguous_width(fd, out, os.get_terminal_size().lines)
            if measured:
                AMBIG = measured
        while True:
            size = os.get_terminal_size()
            lines = read_lines()
            ranges = block_ranges(lines)
            index = read_index()
            # 「N番目のブロック＝索引のN番目」。数が合わない時は選択を諦める
            # （レンダリング途中の一瞬など。次のティックで直る）。
            usable = index if len(index) == len(ranges) else []
            ids = [e.get("session_id") for e in usable]
            sel = ids.index(sel_id) if sel_id in ids else (0 if ids else None)
            sel_id = ids[sel] if sel is not None else None
            if mode == "detail" and sel is None:
                mode = "list"
            if sel is None:
                pending = False

            if mode == "detail":
                frame, scroll = build_detail(usable[sel], scroll, size.columns, size.lines)
            else:
                frame = build_list(lines, ranges, sel, size.columns, size.lines, pending)

            if frame != prev:
                out.write(HOME + (EL + "\r\n").join(frame) + EL + ED)
                out.flush()
                prev = frame

            deadline = time.monotonic() + INTERVAL
            while True:
                timeout = deadline - time.monotonic()
                if timeout <= 0:
                    break
                ready, _, _ = select.select([fd, rpipe], [], [], timeout)
                if rpipe in ready:  # シグナル（主に SIGWINCH）→ 即再描画
                    try:
                        os.read(rpipe, 4096)
                    except BlockingIOError:
                        pass
                    prev = None
                    break
                if fd not in ready:
                    continue

                key = read_key(fd)
                page = max(1, size.lines - 3)
                if pending:
                    # 確認中は q も含めて全キーをここで食う（誤爆と誤終了の両方を防ぐ）
                    if key in (b"y", b"Y") and sel is not None:
                        # 消した後の選択位置は次（無ければ前）のセッションへ寄せる
                        nxt = None
                        if sel + 1 < len(ids):
                            nxt = ids[sel + 1]
                        elif sel > 0:
                            nxt = ids[sel - 1]
                        dismiss(sel_id)
                        sel_id = nxt
                    pending = False
                    prev = None
                    break
                if key in (b"q", b"Q", b"\x03", b""):
                    return 0
                if mode == "list":
                    if key in (b"x", b"X") and sel is not None:
                        pending = True
                    elif key in (b"j", b"DOWN") and sel is not None:
                        sel_id = ids[min(sel + 1, len(ids) - 1)]
                    elif key in (b"k", b"UP") and sel is not None:
                        sel_id = ids[max(sel - 1, 0)]
                    elif key in (b"\r", b"\n") and sel is not None:
                        mode, scroll = "detail", 0
                    elif key == b"\x1b":
                        return 0
                else:
                    if key in (b"j", b"DOWN"):
                        scroll += 1
                    elif key in (b"k", b"UP"):
                        scroll = max(0, scroll - 1)
                    elif key in (b" ", b"f"):
                        scroll += page
                    elif key == b"b":
                        scroll = max(0, scroll - page)
                    elif key == b"g":
                        scroll = 0
                    elif key == b"G":
                        scroll = 10 ** 6
                    elif key in (b"\x1b", b"\r", b"\n"):
                        mode, scroll = "list", 0
                prev = None
                break
    except KeyboardInterrupt:
        return 0
    finally:
        if saved is not None:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        signal.set_wakeup_fd(-1)
        os.close(rpipe)
        os.close(wpipe)
        out.write(WRAP_ON + CUR_SHOW + ALT_OFF)
        out.flush()


if __name__ == "__main__":
    sys.exit(main())
