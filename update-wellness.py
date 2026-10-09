"""Update only the standalone travel page; never touch the application's main branch."""
import base64, concurrent.futures, io, json, time, urllib.request
from pathlib import Path
from bs4 import BeautifulSoup
from PIL import Image, ImageOps

HOTELS = [
 dict(name='Miramonti Boutique Hotel', place='Hafling · Meraner Land', region='meran', price=2054.35, score='9,7', stars='5 Sterne', badge='Panorama-Favorit', tags=['Infinity-Pool ab 32 °C','Onsen','Waldsauna'], text='Über dem Meraner Talkessel. Mein Favorit für Aussicht und Design.', slug='granpanoramaresidencehotelmiramonti', source='https://www.hotel-miramonti.com/en/mm-spa/infinity-pool/', image='https://www.hotel-miramonti.com/site/assets/files/6142/church_of_st_kathrein_-_infinity_pool_6_c_patrick_schwienbacher.0x1060.jpg', credit='MIRAMONTI / Patrick Schwienbacher'),
 dict(name='Der Mesnerwirt', place='Hafling · Meraner Land', region='meran', price=857.55, score='9,0', stars='4 Sterne Superior', badge='Preis-Tipp', tags=['Infinity-Pool','Ganzjährig beheizt','Spa & Sauna'], text='17 × 7 m Natur-Infinity-Pool und Blick Richtung Ifinger.', slug='der-mesnerwirt', source='https://www.mesnerwirt.it/en/wellness-vacation-avelengo-merano/infinity-pool/', image='https://www.mesnerwirt.it/fileadmin/_processed_/8/a/csm_Mesnerwirt-Bio_infinitypool-Sonnenaufgang-Sonnenuntergang-Meran-hafling_8eb1e982a3.jpg', credit='Hotel Mesnerwirt'),
 dict(name='Falkensteiner Kronplatz', place='Reischach / Bruneck · Pustertal', region='pustertal', price=1257.74, score='9,2', stars='5 Sterne', badge='Rooftop & Design', tags=['Rooftop-Infinity-Pool','25-m-Sportpool','1.400 m² Spa'], text='Kronplatz-Panorama, Hamam und Bergsauna. Nicht das Hotel in Bozen.', slug='falkensteiner-kronplatz', source='https://www.falkensteiner.com/hotel-kronplatz/wellness-spa', image='https://image-tc.galaxy.tf/wijpeg-bz7istnn4rf44r3m93osbwk3w/falkensteiner-hotel-kronplatz-pool-1920x1080jpg.jpg?width=1920', credit='Falkensteiner Hotels & Residences'),
 dict(name='Terentnerhof', place='Terenten · Pustertal', region='pustertal', price=1523.58, score='9,6', stars='4 Sterne Superior', badge='Sky Pool', tags=['Infinity-Sky-Pool','Ganzjährig beheizt','XXL-Whirlpool'], text='Dachterrasse mit Bergblick. 8 × 4 m Whirlpool mit 35 °C.', slug='terentnerhof', source='https://www.terentnerhof.com/en/panoramic-infinity-sky-pool/', image='https://www.terentnerhof.com/wp-content/uploads/pool2-terentnerhof.jpg', credit='Hotel Terentnerhof'),
 dict(name='Chalet Mirabell', place='Hafling · Meraner Land', region='meran', price=2597.63, score='9,3', stars='5 Sterne', badge='Luxus-Spa', tags=['33 °C Infinity-Pool','25-m-Sunset-Pool','6.000 m² Spa'], text='Grosszügige Poollandschaft, Panorama-Saunen und Adults-only-Bereiche.', slug='geniesserhotel-mirabell', source='https://www.chalet-mirabell.com/de/day-spa-suedtirol/27-0.html', image='https://www.chalet-mirabell.com/images/content/105792_11661_1_C_1920_1080_0_3696771/day-spa-suedtirol-wellnesshotel-mirabell-meran.jpg', credit='Chalet Mirabell'),
 dict(name='Viktoria Alpine Hideaway', place='Hafling · Meraner Land', region='meran', price=2483.00, score='9,4', stars='4 Sterne', badge='Wald & Wellness', tags=['25-m-Infinity-Pool','Adults-only Sky Pool','6.000 m² Spa'], text='Am Waldrand: viel Grün, Saunen und Bergblick vom Pool.', slug='viktoria-kg-d-platzer-manfred', source='https://www.hotel-viktoria.com/en/living/good-to-know/', image='https://www.hotel-viktoria.com/fileadmin/_processed_/8/5/csm_4-sterne-hotel-hafling-meran-suedtirol-0714_4e0eb6b410.jpg', credit='Viktoria Alpine Hideaway')
]

def embed(h):
    err = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(h['image'], headers={'User-Agent':'Mozilla/5.0','Accept':'image/avif,image/webp,image/*,*/*;q=0.8'})
            with urllib.request.urlopen(req, timeout=30) as res:
                data = res.read(15000000)
            im = ImageOps.exif_transpose(Image.open(io.BytesIO(data))).convert('RGB')
            assert im.width >= 400 and im.height >= 200, (h['name'],im.size)
            im.thumbnail((1200,900))
            buf=io.BytesIO(); im.save(buf,format='JPEG',quality=85,optimize=True)
            h['embedded']='data:image/jpeg;base64,'+base64.b64encode(buf.getvalue()).decode()
            h['image_size']=list(im.size)
            print('PHOTO OK:',h['name'],im.size,len(buf.getvalue()),flush=True)
            return h
        except Exception as exc:
            err=exc; time.sleep(1+attempt)
    raise RuntimeError(h['name']+': '+str(err))

with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    hotels=list(pool.map(embed,HOTELS))
p=Path('index.html')
soup=BeautifulSoup(p.read_text(encoding='utf-8'),'html.parser')
grid=soup.select_one('.hotel-grid')
assert grid is not None, 'Existing travel hotel section missing'
grid.clear()
grid['id']='wellness-hotels'
head=grid.find_previous_sibling('div',class_='section-head')
head.h2.string='Infinity Pools & Bergblick'
head.select_one('.hint').string='6 neue Hotels · Booking-Auswahl'
intro=BeautifulSoup('<p class="wellness-note"><strong>7.–11.11.2026 · 2 Personen · 1 Zimmer · 4 Nächte.</strong><br>Alle Preise gelten pro Hotel für den ganzen Aufenthalt. Hotelauswahl noch offen; die bisherige 2+2-Aufteilung ist damit nicht festgelegt.</p><div class="wellness-filters" role="group" aria-label="Hotels nach Region filtern"><button type="button" class="active" data-region="all">Alle 6</button><button type="button" data-region="meran">Meraner Land 4</button><button type="button" data-region="pustertal">Pustertal 2</button></div>','html.parser')
for node in list(intro.contents): grid.insert_before(node)
for h in hotels:
    price=f"{h['price']:,.2f}".replace(',','’')
    link='https://www.booking.com/hotel/it/'+h['slug']+'.html?aid=2438770&checkin=2026-11-07&checkout=2026-11-11&no_rooms=1&group_adults=2&selected_currency=CHF'
    markup=f'''<article class="card hotel wellness-hotel" data-region="{h['region']}"><a class="hotel-photo-link" href="{h['source']}" target="_blank" rel="noopener noreferrer"><img class="photo" src="{h['embedded']}" alt="Originalfoto: Pool und Umgebung von {h['name']}" decoding="async"><span class="wellness-badge">{h['badge']}</span></a><div class="info"><div class="hotel-meta"><span class="date">{h['place']}</span><span class="rating">{h['score']} / 10</span></div><h3>{h['name']}</h3><div class="wellness-tags">{''.join('<span>'+t+'</span>' for t in h['tags'])}</div><p>{h['text']}</p><div class="wellness-price"><strong>CHF {price}</strong><span>gesamt · 4 Nächte · 2 Personen</span></div><div class="links"><a class="link-button booking-cta" href="{link}" target="_blank" rel="noopener noreferrer">Auf Booking ansehen ↗</a><a class="link-button" href="{h['source']}" target="_blank" rel="noopener noreferrer">Pool & Spa ↗</a></div><small class="photo-credit">Foto: {h['credit']}</small></div></article>'''
    grid.append(BeautifulSoup(markup,'html.parser'))

note=soup.new_tag('p',attrs={'class':'wellness-note'})
note.string='Meraner Land passt zur bisherigen Route. Bei Terenten oder Kronplatz passen wir die Ausflüge an. Preise sind ein Booking-Snapshot, keine Zusage: Verpflegung, Storno, Ortstaxe sowie Poolbetrieb im November vor der Buchung prüfen.'
grid.insert_after(note)
soup.select_one('.hero img')['src']=hotels[0]['embedded']
soup.select_one('.hero img')['alt']='MIRAMONTI: Infinity-Pool mit Blick auf St. Kathrein und die Berge'
soup.select_one('.hero-copy p').clear()
soup.select_one('.hero-copy p').append(BeautifulSoup('Ab Mellingen · mit dem Auto<br>Wellness, Infinity Pools & Bergpanorama','html.parser'))
soup.find('meta',attrs={'name':'description'})['content']='7.–11. November 2026: sechs Wellnesshotels mit echten Poolfotos und Booking-Preisen für zwei Personen.'
for row in soup.select('.day'):
    if 'Mo · 09.11.' in row.get_text():
        row.select_one('span').string='Bozen oder Spa-Tag · abhängig vom gewählten Hotel.'
footer=soup.select_one('.footer')
newp=soup.new_tag('p'); newp.string='Hotelvergleich: Booking.com, 09.10.2026, jeweils 07.–11.11.2026 / 2 Erwachsene / 1 Zimmer. Keine Reservierung. Originalfotos zeigen unterschiedliche Jahreszeiten und keine zugesicherte Zimmeraussicht.'
footer.insert(0,newp)
credits=soup.new_tag('p')
credits.append('Neue Hotelfotos und Wellness-Angaben: ')
for i,h in enumerate(hotels):
    a=soup.new_tag('a',href=h['source'],target='_blank',rel='noopener noreferrer');a.string=h['credit'];credits.append(a);credits.append(' · ' if i<len(hotels)-1 else '.')
soup.select_one('details').insert(1,credits)
style=soup.new_tag('style')
style.string='''.wellness-note{font-size:12px;color:#69726b;line-height:1.6;margin:12px 0 16px}.wellness-note strong{color:#21382e}.wellness-filters{display:flex;flex-wrap:wrap;gap:8px;margin:0 0 18px}.wellness-filters button{border:1px solid #d1d7cf;background:transparent;border-radius:100px;padding:8px 14px;font:12px system-ui;cursor:pointer}.wellness-filters button.active{background:#21382e;color:white;border-color:#21382e}.hotel-photo-link{display:block;position:relative}.wellness-hotel .photo{height:270px}.wellness-badge{position:absolute;left:14px;bottom:14px;background:rgba(255,255,255,.96);color:#21382e;padding:6px 11px;border-radius:100px;font:600 11px system-ui}.hotel-meta{display:flex;gap:8px;align-items:center;justify-content:space-between}.hotel-meta .date{font-size:10px;letter-spacing:.055em}.rating{border-radius:6px;background:#edf2e9;padding:4px 7px;font-size:11px;white-space:nowrap}.wellness-tags{display:flex;flex-wrap:wrap;gap:5px;margin-top:12px}.wellness-tags span{border:1px solid #e1e5dc;border-radius:50px;padding:4px 8px;font-size:10px;color:#315042}.wellness-price{display:flex;flex-wrap:wrap;gap:3px 10px;align-items:baseline;margin:14px 0}.wellness-price strong{font:600 24px Georgia,serif;white-space:nowrap}.wellness-price span{font-size:10px;color:#657167}.booking-cta{background:#21382e!important;color:white!important;border-color:#21382e!important}.photo-credit{display:block;font-size:9px;color:#7c817a;margin-top:10px}.wellness-hotel[hidden]{display:none!important}@media(max-width:650px){.wellness-hotel .photo{height:230px}.wellness-note{font-size:11px}.hotel-meta .date{font-size:9px}.section-head{flex-wrap:wrap;gap:5px}.wellness-price strong{font-size:23px}}'''
soup.head.append(style)
script=soup.new_tag('script')
script.string="document.querySelectorAll('.wellness-filters button').forEach(b=>b.addEventListener('click',()=>{document.querySelectorAll('.wellness-filters button').forEach(x=>x.classList.toggle('active',x===b));document.querySelectorAll('.wellness-hotel').forEach(c=>c.hidden=b.dataset.region!=='all'&&c.dataset.region!==b.dataset.region)}));"
soup.body.append(script)
assert len(soup.select('.wellness-hotel'))==6
assert all(im.get('src','').startswith('data:image/') for im in soup.select('img'))
p.write_text(str(soup),encoding='utf-8')
records=[{k:v for k,v in h.items() if k!='embedded'} for h in hotels]
Path('wellness-status.json').write_text(json.dumps({'status':'images_embedded','hotel_count':6,'image_count':len(soup.select('img')),'prices_for':'2026-11-07 to 2026-11-11; 2 adults; 1 room; 4 nights','hotels':records},ensure_ascii=False,indent=2),encoding='utf-8')
print('READY:',len(soup.select('.wellness-hotel')),'hotels;',len(soup.select('img')),'embedded photos',flush=True)
