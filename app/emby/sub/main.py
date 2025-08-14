import logging
import os
import time
import json
import signal
import threading
import subprocess
import requests
from datetime import datetime
from bs4 import BeautifulSoup

logging.basicConfig(
    level=logging.INFO,  # 日志级别
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler()  # 只输出到控制台
    ]
)

CONFIG_FILE = "config.json"
CONFIG_DIR = os.getenv("CONFIG_DIR", "/sub/data/configs")
RESULT_DIR = os.getenv("RESULT_DIR", "/sub/data/results")
SCAN_DIR = os.getenv("SCAN_DIR", "/sub/media")
SCAN_INTERVAL = int(os.getenv("SCAN_INTERVAL", 86400))
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

def _save_last_scan_time(dt):
    file_path = os.path.join(CONFIG_DIR, CONFIG_FILE)
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(file_path, "w", encoding="utf-8") as f:
        json.dump({"last_scan_time": dt.strftime("%Y-%m-%d %H:%M:%S")}, f, indent=4)

def scan_new_files():
    last_scan_time = _load_last_scan_time()
    cmd = [
        "find", SCAN_DIR, "-maxdepth", "1", "-type", "f",
        "-name", "*.mp4",
        "-newermt", last_scan_time,
        "-printf", "%f\n"
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    files = result.stdout.strip().split("\n") if result.stdout.strip() else []
    mtimes_max = 0
    for f in files:
        full_path = os.path.join(SCAN_DIR, f)
        if os.path.exists(full_path):
            mtimes = os.path.getmtime(full_path)
            if mtimes > mtimes_max:
                mtimes_max = mtimes
    if mtimes_max != 0:
        _save_last_scan_time(datetime.fromtimestamp(mtimes_max))
        
    filtered = [f for f in files if not (f.lower().endswith("-c.mp4") or f.lower().endswith("-uc.mp4"))]
    result_files = []
    for f in filtered:
        base_name = os.path.splitext(f)[0]
        srt_path = os.path.join(SCAN_DIR, base_name + ".chi.srt")
        if not os.path.exists(srt_path):
            result_files.append(base_name)

    return result_files

def _fetch_and_sort(search_code):
    if search_code.lower().endswith("-u"):
        search_code = search_code[:-2]
    url = f"{BASE_URL}/index.php?search={search_code}"
    resp = requests.get(url, headers=HEADERS, timeout=60)
    resp.raise_for_status()

    soup = BeautifulSoup(resp.text, "html.parser")
    table = soup.find("table", class_="table sub-table")
    if not table:
        logging.warning("未找到 <table class='table sub-table'>")
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
                num = 0
                try:
                    for col in cols:
                        if "downloads" in col.get_text(strip=True):
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
    try:
        resp = requests.get(url, headers=HEADERS, timeout=60)
        resp.raise_for_status()
        if len(resp.content) < 800:
            logging.warning(f"下载内容过小 (<800B)，可能无效: {url}")
            return False
        filename = f"{search_code}.chi.srt"
        file_path = os.path.join(SAVE_DIR, filename)
        with open(file_path, "wb") as f:
            f.write(resp.content)
        return True
    except Exception as e:
        return False

def srt_download(search_code):
    os.makedirs(SAVE_DIR, exist_ok=True)
    search_code = search_code.lower()
    try:
        sorted_items = _fetch_and_sort(search_code)
        if not sorted_items:
            logging.warning("没有匹配的字幕链接")
            return 1
        for cnt, link in sorted_items:
            logging.info(f"尝试下载 {cnt} 个下载次数的链接 → {link}")
            srt_link = _find_chinese_download_link(link)
            if srt_link:
                logging.info(f"找到中文字幕下载链接: {srt_link}")
                if _download_srt_file(srt_link, search_code):
                    logging.info(f"---------------已下载字幕文件: {search_code}")
                    return 0
                continue
    except requests.exceptions.HTTPError as e:
        logging.error(f"[HTTP错误] 状态码: {e.response.status_code}")
        return 3
    except requests.exceptions.Timeout:
        logging.error("[超时]")
        return 4
    except requests.exceptions.RequestException as e:
        logging.error(f"[网络错误] {e}")
        return 5
    except Exception as e:
        logging.error(f"[未知错误] {e}")
        return 6
    
    logging.warning("未找到中文字幕下载链接")
    return 2

def append_result(result, type_name):
    os.makedirs(RESULT_DIR, exist_ok=True)
    file_path = os.path.join(RESULT_DIR, str(type_name))
    try:
        with open(file_path, "a", encoding="utf-8") as f:
            f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}  {result}\n")
    except Exception as e:
        logging.error(f"结果写入失败: {e}")

stop_event = threading.Event()
def signal_handler(sig, frame):
    logging.warning("收到退出信号，正在停止...")
    stop_event.set()

def main():
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    while not stop_event.is_set():
        new_files = scan_new_files()

        if new_files:
            logging.info(f"发现 {len(new_files)} 个新文件：")
            for name in new_files:
                res = srt_download(name)
                append_result(name, res)
        else:
            logging.info("没有新文件")

        logging.info(f"等待 {SCAN_INTERVAL} 秒后继续扫描")
        stop_event.wait(SCAN_INTERVAL)

if __name__ == "__main__":
    main()
