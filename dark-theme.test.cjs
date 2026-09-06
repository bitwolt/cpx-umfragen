const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const html=fs.readFileSync('index.html','utf8');
test('CPX survey cards use dark Bitwolt palette',()=>{
  assert.match(html,/text_color:\s*"#eaf6fc"/i);
  assert.match(html,/box_background_color:\s*"#102331"/i);
  assert.match(html,/topbar_background_color:\s*"#05B9F2"/i);
  assert.doesNotMatch(html,/box_background_color:\s*"white"/i);
});
test('CPX page canvas is dark instead of transparent/white',()=>{
  assert.match(html,/html,\s*body\s*\{[\s\S]*background:\s*#0b1822\s*!important/i);
  assert.match(html,/#fullcontent\s*\{[\s\S]*background:\s*#0b1822\s*!important/i);
});
test('CPX honors light theme query without changing survey identity',()=>{
  assert.match(html,/urlParams\.get\(["']theme["']\)/i);
  assert.match(html,/#f4f7fa/i);
  assert.match(html,/#102238/i);
  assert.match(html,/#ffffff/i);
  assert.match(html,/app_id:\s*28226/i);
  assert.match(html,/ext_user_id:\s*userId/i);
});
