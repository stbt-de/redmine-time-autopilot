// Formular „Zuordnung“: Felder je nach Art (kind) und Ziel (target) zeigen.
// data-ta-show="kind:path,branch" ist sichtbar, wenn das Feld mit
// data-ta-toggle="kind" einen der Werte hat.
(function () {
  function update(form) {
    var values = {};
    form.querySelectorAll('[data-ta-toggle]').forEach(function (field) {
      values[field.getAttribute('data-ta-toggle')] = field.value;
    });
    form.querySelectorAll('[data-ta-show]').forEach(function (element) {
      var visible = element.getAttribute('data-ta-show').split(' ').every(function (condition) {
        var parts = condition.split(':');
        return parts[1].split(',').indexOf(values[parts[0]]) !== -1;
      });
      element.hidden = !visible;
    });
  }

  // Ticketsuche (Nummer oder Betreff) über jQuery-UI-Autocomplete aus Redmine.
  // Wer sucht, meint ein anderes Ticket als die Vorschläge: Auswahl dort aufheben.
  function initIssueSearch(input) {
    var clearChoice = function () {
      if (!input.value.trim()) return;
      var form = input.closest('form');
      if (!form) return;
      form.querySelectorAll('input[type=radio][name=choice]').forEach(function (radio) { radio.checked = false; });
    };
    input.addEventListener('input', clearChoice);
    if (window.jQuery && window.jQuery.fn.autocomplete) {
      window.jQuery(input).autocomplete({
        source: input.getAttribute('data-ta-issue-search'),
        minLength: 2,
        position: { collision: 'flipfit' },
        select: function (event, ui) {
          input.value = ui.item.value;
          clearChoice();
          return false;
        }
      });
    }
  }

  // Redmine fokussiert beim Laden das erste Textfeld (defaultFocus). Auf der
  // Seite „Zeiten“ sind das Suchfeld oder Stunden weit unten – die Seite würde
  // dorthin springen. Fokus wieder lösen und oben bleiben.
  function undoDefaultFocus() {
    if (!document.querySelector('.ta-split') || window.location.hash) return;
    var focused = document.activeElement;
    if (focused && focused !== document.body && focused.closest('#content')) {
      focused.blur();
      window.scrollTo(0, 0);
    }
  }

  function init() {
    undoDefaultFocus();
    document.querySelectorAll('[data-ta-issue-search]').forEach(initIssueSearch);
    document.querySelectorAll('.ta-rule-form').forEach(function (box) {
      var form = box.closest('form') || box;
      form.querySelectorAll('[data-ta-toggle]').forEach(function (field) {
        field.addEventListener('change', function () { update(form); });
      });
      update(form);
    });
  }

  // Nach Redmines eigenem Start (jQuery ready), damit defaultFocus schon lief
  if (window.jQuery) {
    window.jQuery(function () { setTimeout(init, 0); });
  } else if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
