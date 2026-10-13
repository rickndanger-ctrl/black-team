// Black Team Agent website: fills in the current version and direct download links.
// The page works without this file: every download link falls back to the releases page.
// To bump the version, change data-version on <body> in index.html and the static
// version text next to it (search for the old version string), then redeploy.
(function () {
  'use strict';
  var body = document.body;
  var version = body && body.getAttribute('data-version');
  if (!version) return;

  var repo = 'https://github.com/rickndanger-ctrl/black-team';
  var base = repo + '/releases/download/v' + version + '/';
  var files = {
    linux: 'black-team-' + version + '-linux-x64.tar.gz',
    mac: 'Black-Team-' + version + '-mac-arm64.zip'
  };

  Array.prototype.forEach.call(document.querySelectorAll('[data-version-text]'), function (el) {
    el.textContent = version;
  });

  // Only the two large buttons link straight to the file. The steps keep the releases page.
  Array.prototype.forEach.call(document.querySelectorAll('a.btn[data-dl]'), function (a) {
    var file = files[a.getAttribute('data-dl')];
    if (file) a.setAttribute('href', base + file);
  });
}());
