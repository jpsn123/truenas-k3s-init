import os
import time
import json
import signal
import subprocess
import requests
from datetime import datetime
from bs4 import BeautifulSoup

CONFIG_FILE = "config.json"
CONFIG_DIR = os.getenv("CONFIG_DIR", "/sub/config")
SCAN_DIR = os.getenv("SCAN_DIR", "/media")
SCAN_INTERVAL = os.getenv("SCAN_INTERVAL", "86400")
SAVE_DIR = os.getenv("SAVE_DIR", "/sub/downloads")
BASE_URL = "https://subtitlecat.com"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
}

def _load_last_scan_time():    
    file_path = os.path.join(CONFIG_DIR, CONFIG_FILE)
    if not os.path.exists(file_path):
        return "1970-01-01 00:00:00"
    with open(file_path, "r", encoding="utf-8") as f:
        return json.load(f).get("last_scan_time", "1970-01-01 00:00:00")

def _save_last_scan_time():
    file_path = os.path.join(CONFIG_DIR, CONFIG_FILE)
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(file_path, "w", encoding="utf-8") as f:
        json.dump({"last_scan_time": datetime.now().strftime("%Y-%m-%d %H:%M:%S")}, f, indent=4)

def scan_new_files():
    last_scan_time = _load_last_scan_time()
    cmd = [
        "find", SCAN_DIR, "-maxdepth", "1", "-type", "f",
        "-name", "'*.mp4'",
        "-newermt", last_scan_time,
        "-printf", "%f\n"
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    _save_last_scan_time()
    files = result.stdout.strip().split("\n") if result.stdout.strip() else []
    filtered = [f for f in files if not f.lower().endswith("-c.mp4")]
    result = []
    for f in filtered:
        base_name = os.path.splitext(f)[0]
        srt_path = os.path.join(SCAN_DIR, base_name + ".chi.srt")
        if not os.path.exists(srt_path):
            result.append(f)

    return result

def _fetch_and_sort(search_code):
    url = f"{BASE_URL}/index.php?search={search_code}"
    resp = requests.get(url, headers=HEADERS, timeout=60)
    resp.raise_for_status()

    soup = BeautifulSoup(resp.text, "html.parser")
    table = soup.find("table", class_="table sub-table")
    if not table:
        print("未找到 <table class='table sub-table'>")
        return []

    rows = table.find_all("tr")
    items = []
    for tr in rows:
        a = tr.find("a")
        cols = tr.find_all("td")
        if a and cols and len(cols) >= 3:
            text = a.get_text(strip=True)
            search_clean = search_code.lower().replace("-", "").replace(" ", "")
            text_clean = text.lower().replace("-", "").replace(" ", "")
            if search_clean in text_clean:
                try:
                    for col in cols:
                        if  "downloads" in col.get_text(strip=True):
                            num = int(col.get_text(strip=True).replace("downloads", ""))
                except ValueError:
                    num = 0
                link = a.get("href")
                if link and not link.startswith("http"):
                    link = BASE_URL + "/" + link
                items.append((num, link))
    items.sort(key=lambda x: x[0], reverse=True)
    return items

def _find_chinese_download_link(page_url):
    resp = requests.get(page_url, headers=HEADERS, timeout=60)
    resp.raise_for_status()

    soup = BeautifulSoup(resp.text, "html.parser")
    sub_divs = soup.find_all("div", class_="sub-single")

    for div in sub_divs:
        if "Chinese (Simplified)" in div.get_text():
            a_tag = div.find("a", href=True)
            if a_tag:
                link = a_tag["href"]
                if not link.startswith("http"):
                    link = BASE_URL + link
                return link
    return None

def _download_srt_file(url, search_code):
    resp = requests.get(url, headers=HEADERS, timeout=60)
    resp.raise_for_status()
    filename = f"{search_code}.chi.srt"
    file_path = os.path.join(SAVE_DIR, filename)
    with open(file_path, "wb") as f:
        f.write(resp.content)
    print(f"已下载字幕文件: {filename}")

def srt_download(search_code):
    os.makedirs(SAVE_DIR, exist_ok=True)
    search_code = search_code.lower()
    try:
        sorted_items = _fetch_and_sort(search_code)
        if not sorted_items:
            print("没有匹配的字幕链接")
            return 1
        else:
            for cnt, link in sorted_items:
                print(f"尝试下载 {cnt} 个下载次数的链接 → {link}")
                srt_link = _find_chinese_download_link(link)
                if srt_link:
                    print(f"  找到中文字幕下载链接: {srt_link}")
                    _download_srt_file(srt_link, search_code)
                    return 0
                else:
                    print("  未找到中文字幕下载链接")
    except requests.exceptions.HTTPError as e:
        print(f"[HTTP错误] 状态码: {e.response.status_code}")
        return 3
    except requests.exceptions.Timeout:
        print(f"[超时]")
        return 4
    except requests.exceptions.RequestException as e:
        print(f"[网络错误] 错误: {e}")
        return 5
    except Exception as e:
        print(f"[未知错误] 错误: {e}")
        return 6
    return 2

def append_result(result, type_name):
    file_path = f"/result/{type_name}"
    try:
        with open(file_path, "a", encoding="utf-8") as f:
            f.write(f"{result}\n")
        print(f"已写入: {file_path}")
    except Exception as e:
        print(f"写入失败: {e}")


stop_flag = False
def signal_handler(sig, frame):
    global stop_flag
    print("\n收到退出信号，正在停止...")
    stop_flag = True

def main():
    global stop_flag
    signal.signal(signal.SIGINT, signal_handler)  # Ctrl+C
    signal.signal(signal.SIGTERM, signal_handler) # kill 命令

    while not stop_flag:
        now = datetime.now()
        new_files = scan_new_files()

        if new_files:
            print(f"发现 {len(new_files)} 个新文件：")
            for name in new_files:
                res = srt_download(name)
                append_result(name, res)
        else:
            print("没有新文件")

        time.sleep(int(SCAN_INTERVAL))

if __name__ == "__main__":
    main()
