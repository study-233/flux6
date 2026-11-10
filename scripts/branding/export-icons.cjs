#!/usr/bin/env node
// Render all platform assets from the approved SVG sources. Requires sharp 0.34+.
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require(process.env.FREEV6_SHARP_MODULE || 'sharp');
const root = path.resolve(__dirname, '../..');
const cats = path.join(root, 'assets/branding/cats');
async function write(name, bytes) {
  const target = path.join(root, name);
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.writeFile(target, bytes);
}
function ico(images) {
  const header = Buffer.alloc(6 + images.length * 16);
  header.writeUInt16LE(1, 2); header.writeUInt16LE(images.length, 4);
  let offset = header.length;
  images.forEach(({ size, data }, index) => {
    const at = 6 + index * 16;
    header[at] = header[at + 1] = size === 256 ? 0 : size;
    header.writeUInt16LE(1, at + 4); header.writeUInt16LE(32, at + 6);
    header.writeUInt32LE(data.length, at + 8); header.writeUInt32LE(offset, at + 12);
    offset += data.length;
  });
  return Buffer.concat([header, ...images.map(i => i.data)]);
}
async function main() {
  const catalog = JSON.parse(await fs.readFile(path.join(cats, 'catalog.json'), 'utf8'));
  const res = 'apps/android/android/app/src/main/res';
  for (const { id } of catalog.icons) {
    const source = path.join(cats, id + '.svg');
    const png = size => sharp(source, { density: 144 }).resize(size, size).png().toBuffer();
    const image = await png(512);
    await write(`assets/branding/cats/native/${id}.rgba`, await sharp(source).resize(64).ensureAlpha().raw().toBuffer());
    await write(`assets/branding/cats/${id}.png`, image);
    await write(`apps/windows/web/branding/${id}.svg`, await fs.readFile(source));
    for (const platform of ['macos', 'android']) {
      const base = platform === 'macos' ? 'apps/macos/flutter_ui/assets/branding/cats' : 'apps/android/assets/images/cats';
      await write(`${base}/${id}.png`, image);
    }
    const set = `apps/macos/flutter_ui/macos/Runner/Assets.xcassets/cat-${id}.imageset`;
    await write(`${set}/icon.png`, image);
    await write(`${set}/Contents.json`, JSON.stringify({ images: [{ filename: 'icon.png', idiom: 'universal' }], info: { author: 'xcode', version: 1 } }, null, 2) + '\n');
    // An adaptive icon has a 108 dp canvas; keep the complete cat inside its mask-safe area.
    const foreground = await png(248);
    const adaptive = await sharp({create:{width:432,height:432,channels:4,background:'#00000000'}})
      .composite([{input:foreground,left:92,top:92}]).png().toBuffer();
    const resource = 'cat_' + id.replaceAll('-', '_');
    await write(`${res}/drawable-nodpi/${resource}_foreground.png`, adaptive);
    await write(`${res}/mipmap-anydpi-v26/${resource}.xml`, `<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n    <background android:drawable="@color/ic_launcher_background"/>\n    <foreground android:drawable="@drawable/${resource}_foreground"/>\n    <monochrome android:drawable="@drawable/cat_monochrome"/>\n</adaptive-icon>\n`);
    // Pre-26 launchers resolve this density-independent resource.
    await write(`${res}/mipmap-nodpi/${resource}.png`, image);
    if (id !== catalog.default) continue;
    const svg = await fs.readFile(source, 'utf8');
    const body = svg.match(/id="cat-[^"]+-body-shape" d="([\s\S]*?)"/)[1];
    const tail = svg.match(/id="cat-[^"]+-tail" d="([\s\S]*?)"/)[1];
    const holes = ' M128.5 180 A18.5 18.5 0 1 0 165.5 180 A18.5 18.5 0 1 0 128.5 180 Z M242.5 180 A18.5 18.5 0 1 0 279.5 180 A18.5 18.5 0 1 0 242.5 180 Z M173.75 209 C176 229 195 231 204 221 C213 231 232 229 234.25 209 C235 202 224 202 223.75 209 C221 217 212 218 208 211 C205 207 203 207 200 211 C196 218 187 217 184.25 209 C183 202 173 202 173.75 209 Z';
    const vector = (scale, translate, dp) => `<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="${dp}dp" android:height="${dp}dp" android:viewportWidth="512" android:viewportHeight="512">
    <group android:scaleX="${scale}" android:scaleY="${scale}" android:translateX="${translate}" android:translateY="${translate}">
        <path android:pathData="${tail}" android:strokeWidth="58" android:strokeLineCap="round" android:strokeColor="#FFFFFFFF" />
        <path android:pathData="${body + holes}" android:fillType="evenOdd" android:fillColor="#FFFFFFFF" />
    </group>
</vector>\n`;
    await write(`${res}/drawable/cat_monochrome.xml`, vector(.94*248/432, (92*512+15.36*248)/432, 108));
    await write('apps/android/android/service/src/main/res/drawable/ic.xml', vector(.94, 15.36, 24));
    await write('assets/branding/icon.svg', await fs.readFile(source));
    for (const [file,size] of [['icon.png',1024],['32x32.png',32],['128x128.png',128],['128x128@2x.png',256]])
      await write('assets/branding/'+file, await png(size));
    const icon = ico(await Promise.all([16,24,32,48,64,128,256].map(async size => ({size,data:await png(size)}))));
    await write('assets/branding/icon.ico', icon);
    await write('apps/android/assets/images/icon.ico', icon);
    await write('apps/android/assets/images/icon.png', image);
    await write(`${res}/drawable/freev6_icon.png`, image);
    for(const size of [32,128]) await write(`cmd/freev6-helper/winres/icon${size}.png`, await png(size));
    for(const size of [16,32,64,128,256,512,1024]) await write(`apps/macos/flutter_ui/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${size}.png`, await png(size));
    const flutterRunner = path.join(root,'apps/windows/flutter_ui/windows/runner/resources');
    try { await fs.access(flutterRunner); await write('apps/windows/flutter_ui/windows/runner/resources/app_icon.ico',icon); } catch(error) { if(error.code !== 'ENOENT') throw error; }
    for(const [density,size,tvSize] of [['mdpi',48,80],['hdpi',72,120],['xhdpi',96,160],['xxhdpi',144,240],['xxxhdpi',192,320]]) {
      for(const name of ['ic_launcher','ic_launcher_round']) await write(`${res}/mipmap-${density}/${name}.webp`,await sharp(source).resize(size).webp({lossless:true}).toBuffer());
      await write(`${res}/mipmap-television-${density}/ic_launcher.webp`,await sharp(source).resize(tvSize).webp({lossless:true}).toBuffer());
    }
    await write(`${res}/mipmap-xhdpi/ic_banner.png`, await sharp({create:{width:320,height:180,channels:4,background:'#F7F9FB'}}).composite([{input:await png(150),left:85,top:15}]).png().toBuffer());
  }
  await write('assets/branding/cats/preview.png', await sharp(path.join(cats,'preview.svg')).png().toBuffer());
  console.log(`Exported ${catalog.icons.length} themes; default: ${catalog.default}.`);
}
main().catch(error => { console.error(error); process.exitCode=1; });
