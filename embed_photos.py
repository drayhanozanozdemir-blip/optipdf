"""Produce a self-contained trip page without external image dependencies."""
import base64
import concurrent.futures
import hashlib
import html
import json
import re
import time
import urllib.request
from pathlib import Path

page_path = Path('index.html')
page = page_path.read_text(encoding='utf-8')
urls = sorted(set(html.unescape(u) for u in re.findall(r'<img[^>]+src="(https://[^"]+)"', page)))

def download(url):
    candidates = [url]
    if 'thumb.wikimedia.org' in url:
        candidates.append(url.replace('thumb.wikimedia.org', 'upload.wikimedia.org'))
    errors = []
    for attempt in range(3):
        for candidate in candidates:
            try:
                request = urllib.request.Request(candidate, headers={'User-Agent':'SuedtirolTripPage/1.0 (personal non-commercial itinerary)', 'Accept':'image/*'})
                with urllib.request.urlopen(request, timeout=35) as response:
                    data = response.read(12000000)
                    mime = response.headers.get_content_type()
                if data[:3] == b'\xff\xd8\xff': mime = 'image/jpeg'
                elif data[:8] == b'\x89PNG\r\n\x1a\n': mime = 'image/png'
                elif data[:4] == b'RIFF' and data[8:12] == b'WEBP': mime = 'image/webp'
                else: raise ValueError('Response is not a supported image')
                if len(data) < 1000 or len(data) >= 12000000: raise ValueError('Unexpected image size')
                print('Downloaded', url, len(data), flush=True)
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
Path('publication-status.json').write_text(json.dumps({'status':'ready','embedded_images':7,'unique_photos':len(records),'html_bytes':page_path.stat().st_size,'photos':records}, indent=2), encoding='utf-8')
print('Ready: all original photos embedded directly in index.html', flush=True)
