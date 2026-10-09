"""Embed authentic trip photos, publish on the isolated branch and check a public viewer."""
import base64
import concurrent.futures
import hashlib
import html
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

BRANCH = 'reise-suedtirol-2026'
REPO = 'drayhanozanozdemir-blip/optipdf'
page_path = Path('index.html')
page = page_path.read_text(encoding='utf-8')
urls = sorted(set(html.unescape(u) for u in re.findall(r'<img[^>]+src="(https://[^"]+)"', page)))

def download(url):
    candidates = [url]
    if 'upload.wikimedia.org/wikipedia/commons/thumb/' in url:
        candidates.insert(0, url.replace('upload.wikimedia.org', 'thumb.wikimedia.org'))
    elif 'thumb.wikimedia.org' in url:
        candidates.append(url.replace('thumb.wikimedia.org', 'upload.wikimedia.org'))
    errors = []
    for attempt in range(3):
        for candidate in candidates:
            try:
                request = urllib.request.Request(candidate, headers={'User-Agent':'SuedtirolTripPage/1.0 (personal non-commercial itinerary)', 'Accept':'image/*'})
                with urllib.request.urlopen(request, timeout=30) as response:
                    data = response.read(12000000)
                    mime = response.headers.get_content_type()
                if data[:3] == b'\xff\xd8\xff': mime = 'image/jpeg'
                elif data[:8] == b'\x89PNG\r\n\x1a\n': mime = 'image/png'
                elif data[:4] == b'RIFF' and data[8:12] == b'WEBP': mime = 'image/webp'
                else: raise ValueError('Response is not a supported image')
                if len(data) < 1000 or len(data) >= 12000000: raise ValueError('Unexpected image size')
                print('Downloaded', candidate, len(data), flush=True)
                return url, 'data:' + mime + ';base64,' + base64.b64encode(data).decode('ascii'), {'url':url, 'bytes':len(data), 'sha256':hashlib.sha256(data).hexdigest()}
            except Exception as exc:
                errors.append(str(exc))
        time.sleep(3 * (attempt + 1))
    raise RuntimeError('Could not download '+url+': '+'; '.join(errors))

records = []
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    for original, data_uri, record in pool.map(download, urls):
        page = page.replace('src="'+original+'"', 'src="'+data_uri+'"')
        records.append(record)
assert len(urls) == 6, f'Expected 6 distinct original photos, found {len(urls)}'
assert len(re.findall(r'<img[^>]+src="data:image/', page)) == 7
assert not re.search(r'<img[^>]+src="https?://', page)
page_path.write_text(page, encoding='utf-8')
report = {'status':'ready','embedded_images':7,'unique_photos':len(records),'html_bytes':page_path.stat().st_size,'photos':records}
Path('publication-status.json').write_text(json.dumps(report, indent=2), encoding='utf-8')

assert subprocess.check_output(['git','branch','--show-current'], text=True).strip() == BRANCH
subprocess.run(['git','config','user.name','Trip page publisher'], check=True)
subprocess.run(['git','config','user.email','41898282+github-actions[bot]@users.noreply.github.com'], check=True)
subprocess.run(['git','add','index.html','publication-status.json'], check=True)
subprocess.run(['git','commit','-m','Embed original Suedtirol trip photos [skip ci]'], check=True)
subprocess.run(['git','push','origin','HEAD:'+BRANCH], check=True)
sha = subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip()
raw = 'https://raw.githubusercontent.com/'+REPO+'/'+sha+'/index.html'
public_url = 'https://htmlpreview.github.io/?'+raw
report['published_commit'] = sha
report['public_url'] = public_url
report['cdn_url'] = 'https://rawcdn.githack.com/'+REPO+'/'+sha+'/index.html'
print('PUBLIC_URL',public_url,flush=True)

try:
    subprocess.run([sys.executable,'-m','pip','install','--quiet','playwright'], check=True, timeout=100)
    from playwright.sync_api import sync_playwright
    chrome = shutil.which('google-chrome') or shutil.which('chromium') or shutil.which('chromium-browser')
    if not chrome:
        subprocess.run([sys.executable,'-m','playwright','install','chromium'], check=True, timeout=150)
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=chrome, headless=True, args=['--no-sandbox'])
        tab = browser.new_page(viewport={'width':390,'height':844}, device_scale_factor=1)
        tab.goto(public_url, wait_until='domcontentloaded', timeout=60000)
        tab.wait_for_selector('.hotel-grid', timeout=60000)
        tab.wait_for_function('Array.from(document.images).filter(i=>i.complete&&i.naturalWidth>0).length === 7', timeout=45000)
        report['browser_test'] = {'public_without_login':True,'mobile_width':390,'loaded_images':tab.evaluate('Array.from(document.images).filter(i=>i.complete&&i.naturalWidth>0).length'),'horizontal_overflow':tab.evaluate('document.documentElement.scrollWidth>window.innerWidth'),'title':tab.title()}
        assert not report['browser_test']['horizontal_overflow']
        tab.screenshot(path='mobile-preview.png', full_page=True)
        tab.set_viewport_size({'width':1280,'height':900})
        tab.screenshot(path='desktop-preview.png', full_page=True)
        report['browser_test']['desktop_width']=1280
        browser.close()
except Exception as exc:
    report['browser_test_error'] = str(exc)
    print('BROWSER_CHECK_ERROR',str(exc),flush=True)
Path('publication-status.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print('PUBLICATION_REPORT',json.dumps(report),flush=True)
