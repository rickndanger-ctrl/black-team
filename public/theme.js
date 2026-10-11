// Applies the saved theme before the first paint, so a Light or Ghost user never sees a flash of Covert.
// Kept as a file rather than an inline script so the page's Content Security Policy can stay at script-src 'self'.
try {
  var saved = localStorage.getItem('black-team-theme');
  document.documentElement.dataset.theme = ['covert', 'light', 'ghost'].indexOf(saved) >= 0 ? saved : 'covert';
} catch (error) {
  document.documentElement.dataset.theme = 'covert';
}
