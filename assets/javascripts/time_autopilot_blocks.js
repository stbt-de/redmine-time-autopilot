// =============================================================================
// Dashboard Blocks – Block "Zeit buchen" auf Meine Seite (dazu unten: Wahl
// des Mitarbeiters in "Wochenstunden")
//
// Ticket suchen (Nummer, Titel, Projekt), Dauer per Schnellwahl, buchen ohne
// Seitenwechsel, Rückgängig. Ohne JavaScript schickt das Formular an
// denselben Endpunkt (Antwort dann als JSON).
//
// Ereignisse hängen am Dokument: Redmine setzt Blöcke beim "Hinzufügen" per
// Ajax ein, der Block funktioniert dann ohne eigenen Start.
// Texte kommen aus data-i18n am Block (config/locales).
// =============================================================================
(function () {
  'use strict';

  var ROOT = '.ta-quick-time';
  var SEARCH_DELAY_MS = 200;

  function rootOf(element) {
    return element && element.closest ? element.closest(ROOT) : null;
  }

  function data(root, name) {
    try {
      return JSON.parse(root.getAttribute('data-' + name) || '{}');
    } catch (error) {
      return {};
    }
  }

  function parts(root) {
    return {
      form: root.querySelector('form'),
      issueId: root.querySelector('input[name="issue_id"]'),
      search: root.querySelector('.ta-issue-search'),
      clear: root.querySelector('.ta-issue-clear'),
      options: root.querySelector('.ta-issue-options'),
      hours: root.querySelector('.ta-hours'),
      customHours: root.querySelector('.ta-hours-custom'),
      activity: root.querySelector('.ta-activity'),
      comments: root.querySelector('input[name="comments"]'),
      status: root.querySelector('.ta-quick-time-status')
    };
  }

  function csrfToken() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.content : '';
  }

  function request(url, options) {
    options = options || {};
    options.credentials = 'same-origin';
    // X-Requested-With: abgelaufene Sitzung → 401 statt Weiterleitung (Redmine)
    options.headers = Object.assign({
      Accept: 'application/json', 'X-CSRF-Token': csrfToken(), 'X-Requested-With': 'XMLHttpRequest'
    }, options.headers || {});
    return fetch(url, options).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (body) {
        return { ok: response.ok, body: body };
      });
    });
  }

  // --- Ticketsuche -----------------------------------------------------------

  function closeOptions(root) {
    var p = parts(root);
    p.options.hidden = true;
    p.options.innerHTML = '';
    p.search.setAttribute('aria-expanded', 'false');
    p.search.removeAttribute('aria-activedescendant');
  }

  function renderOptions(root, issues) {
    var p = parts(root);
    var i18n = data(root, 'i18n');
    p.options.innerHTML = '';

    if (!issues.length) {
      var empty = document.createElement('li');
      empty.className = 'ta-issue-empty';
      empty.textContent = i18n.no_match || '';
      p.options.appendChild(empty);
    }

    issues.forEach(function (issue, index) {
      var option = document.createElement('li');
      option.id = p.options.id + '-' + index;
      option.setAttribute('role', 'option');
      option.className = 'ta-issue-option';
      option.dataset.issueId = issue.id;
      option.dataset.label = '#' + issue.id + ' ' + issue.subject;

      // Kachel stammt vom eigenen Server (Helper, Name ist escaped)
      var tile = document.createElement('span');
      tile.className = 'ta-issue-tile';
      tile.innerHTML = issue.tile || '';

      var text = document.createElement('span');
      text.className = 'ta-issue-text';
      var subject = document.createElement('span');
      subject.className = 'ta-issue-subject';
      subject.textContent = issue.subject;
      // Projekt (wird gekürzt) · Nummer (bleibt sichtbar)
      var meta = document.createElement('span');
      meta.className = 'ta-issue-meta';
      var project = document.createElement('span');
      project.className = 'ta-issue-project';
      project.textContent = issue.project;
      var number = document.createElement('span');
      number.className = 'ta-issue-number';
      number.textContent = '· #' + issue.id;
      meta.appendChild(project);
      meta.appendChild(number);
      text.appendChild(subject);
      text.appendChild(meta);

      option.appendChild(tile);
      option.appendChild(text);
      p.options.appendChild(option);
    });

    p.options.hidden = false;
    p.search.setAttribute('aria-expanded', 'true');
  }

  function search(root) {
    var p = parts(root);
    var query = p.search.value.trim();
    clearTimeout(root._searchTimer);
    if (!query) {
      closeOptions(root);
      return;
    }
    root._searchTimer = setTimeout(function () {
      var url = data(root, 'urls').issues + '?q=' + encodeURIComponent(query);
      request(url).then(function (result) {
        // Inzwischen weitergetippt: alte Antwort verwerfen
        if (p.search.value.trim() !== query || p.issueId.value) {
          return;
        }
        renderOptions(root, result.ok && Array.isArray(result.body) ? result.body : []);
      });
    }, SEARCH_DELAY_MS);
  }

  function moveActive(root, step) {
    var p = parts(root);
    var options = Array.prototype.slice.call(p.options.querySelectorAll('[role="option"]'));
    if (!options.length) {
      return;
    }
    var current = options.findIndex(function (option) { return option.getAttribute('aria-selected') === 'true'; });
    var next = (current + step + options.length) % options.length;
    options.forEach(function (option, index) {
      option.setAttribute('aria-selected', index === next ? 'true' : 'false');
    });
    p.search.setAttribute('aria-activedescendant', options[next].id);
    options[next].scrollIntoView({ block: 'nearest' });
  }

  // --- Auswahl ---------------------------------------------------------------

  function loadActivities(root, issueId) {
    var p = parts(root);
    var url = data(root, 'urls').activities + '?issue_id=' + encodeURIComponent(issueId);
    request(url).then(function (result) {
      if (!result.ok || !Array.isArray(result.body) || !result.body.length) {
        return;
      }
      var selected = p.activity.value;
      var keep = result.body.some(function (activity) { return String(activity.id) === selected; });
      p.activity.innerHTML = '';
      result.body.forEach(function (activity) {
        var option = document.createElement('option');
        option.value = activity.id;
        option.textContent = activity.name;
        option.selected = keep ? String(activity.id) === selected : activity.default;
        p.activity.appendChild(option);
      });
    });
  }

  function selectIssue(root, issueId, label) {
    var p = parts(root);
    p.issueId.value = issueId;
    p.search.value = label;
    p.clear.hidden = false;
    root.classList.add('ta-has-issue');
    closeOptions(root);
    hideStatus(root);
    loadActivities(root, issueId);
  }

  function clearIssue(root) {
    var p = parts(root);
    p.issueId.value = '';
    p.clear.hidden = true;
    root.classList.remove('ta-has-issue');
  }

  // --- Dauer -----------------------------------------------------------------

  // Gebucht wird das versteckte Feld: die eigene Dauer, sonst die gewählte Vorgabe.
  // Eine Vorgabe ist nur markiert, solange das Feld für die eigene Dauer leer ist.
  function markDuration(root) {
    var p = parts(root);
    var custom = p.customHours.value.trim();
    p.hours.value = custom || root.dataset.taPreset || p.hours.defaultValue;
    root.querySelectorAll('.ta-duration-choice').forEach(function (button) {
      button.setAttribute('aria-pressed', !custom && button.dataset.hours === p.hours.value ? 'true' : 'false');
    });
  }

  function choosePreset(root, hours) {
    root.dataset.taPreset = hours;
    parts(root).customHours.value = '';
    markDuration(root);
  }

  // --- Meldungen und Buchen --------------------------------------------------

  function hideStatus(root) {
    var status = parts(root).status;
    status.hidden = true;
    status.innerHTML = '';
    status.className = 'ta-quick-time-status';
  }

  // Meldung als Text; steht die Ticketnummer (issue.label) darin, wird sie zum Link
  function messageNode(text, issue) {
    var message = document.createElement('span');
    var at = issue && issue.label ? text.indexOf(issue.label) : -1;
    if (at < 0) {
      message.textContent = text;
      return message;
    }
    var link = document.createElement('a');
    link.href = issue.url;
    link.textContent = issue.label;
    message.appendChild(document.createTextNode(text.slice(0, at)));
    message.appendChild(link);
    message.appendChild(document.createTextNode(text.slice(at + issue.label.length)));
    return message;
  }

  function showStatus(root, kind, text, action, issue) {
    var status = parts(root).status;
    status.innerHTML = '';
    status.className = 'ta-quick-time-status ta-status-' + kind;
    status.appendChild(messageNode(text, issue));
    if (action) {
      status.appendChild(action);
    }
    status.hidden = false;
  }

  function updateToday(root, today) {
    var block = root.closest('.mypage-box') || document;
    var target = block.querySelector('[data-ta-today]');
    if (target && today) {
      target.textContent = today;
    }
  }

  function undoButton(root, id) {
    var i18n = data(root, 'i18n');
    var button = document.createElement('button');
    button.type = 'button';
    button.className = 'ta-undo';
    button.textContent = i18n.undo;
    button.addEventListener('click', function () {
      var url = data(root, 'urls').destroy.replace(/\/0$/, '/' + id);
      request(url, { method: 'DELETE' }).then(function (result) {
        if (result.ok) {
          updateToday(root, result.body.today);
          showStatus(root, 'info', i18n.undone);
        } else {
          showStatus(root, 'error', (result.body.errors || [i18n.failed]).join(' '));
        }
      });
    });
    return button;
  }

  function submit(root) {
    var p = parts(root);
    var i18n = data(root, 'i18n');
    if (!p.issueId.value) {
      showStatus(root, 'error', i18n.choose_issue);
      p.search.focus();
      return;
    }

    var button = p.form.querySelector('[type="submit"]');
    button.disabled = true;
    request(data(root, 'urls').create, { method: 'POST', body: new FormData(p.form) })
      .then(function (result) {
        if (result.ok) {
          updateToday(root, result.body.today);
          showStatus(root, 'success', result.body.message,
                     result.body.undo ? undoButton(root, result.body.id) : null, result.body.issue);
          clearIssue(root);
          p.search.value = '';
          p.comments.value = '';
          return;
        }
        var link = null;
        if (result.body.form_url) {
          link = document.createElement('a');
          link.href = result.body.form_url;
          link.textContent = i18n.open_form;
        }
        showStatus(root, 'error', (result.body.errors || [i18n.failed]).join(' '), link);
      })
      .catch(function () {
        showStatus(root, 'error', i18n.failed);
      })
      .then(function () {
        button.disabled = false;
      });
  }

  // --- Ereignisse ------------------------------------------------------------

  document.addEventListener('input', function (event) {
    var root = rootOf(event.target);
    if (!root) {
      return;
    }
    if (event.target.matches('.ta-issue-search')) {
      clearIssue(root);
      search(root);
    } else if (event.target.matches('.ta-hours-custom')) {
      markDuration(root);
    }
  });

  document.addEventListener('keydown', function (event) {
    var root = rootOf(event.target);
    if (!root || !event.target.matches('.ta-issue-search')) {
      return;
    }
    var p = parts(root);
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      if (p.options.hidden) {
        search(root);
      } else {
        moveActive(root, event.key === 'ArrowDown' ? 1 : -1);
      }
    } else if (event.key === 'Enter' && !p.options.hidden) {
      var active = p.options.querySelector('[aria-selected="true"]') || p.options.querySelector('[role="option"]');
      if (active) {
        event.preventDefault();
        selectIssue(root, active.dataset.issueId, active.dataset.label);
      }
    } else if (event.key === 'Escape') {
      closeOptions(root);
    }
  });

  document.addEventListener('click', function (event) {
    // Klick außerhalb schließt offene Trefferlisten
    document.querySelectorAll(ROOT).forEach(function (root) {
      if (!root.querySelector('.ta-combobox').contains(event.target)) {
        closeOptions(root);
      }
    });

    var root = rootOf(event.target);
    if (!root) {
      return;
    }
    var option = event.target.closest('.ta-issue-option');
    var recent = event.target.closest('.ta-recent-issue');
    var duration = event.target.closest('.ta-duration-choice');

    if (option) {
      selectIssue(root, option.dataset.issueId, option.dataset.label);
    } else if (recent) {
      selectIssue(root, recent.dataset.issueId, recent.dataset.label);
    } else if (duration) {
      choosePreset(root, duration.dataset.hours);
    } else if (event.target.closest('.ta-issue-clear')) {
      var p = parts(root);
      clearIssue(root);
      p.search.value = '';
      p.search.focus();
    }
  });

  // Wochenstunden: anderer Mitarbeiter → Formular per Ajax (rails-ujs) senden;
  // jQuerys .submit() ginge am Ajax vorbei (Redmine antwortet dann 406)
  document.addEventListener('change', function (event) {
    if (event.target.matches('.ta-mw-user select')) {
      event.target.form.requestSubmit();
    }
  });

  document.addEventListener('submit', function (event) {
    var root = rootOf(event.target);
    if (root) {
      event.preventDefault();
      submit(root);
    }
  });
})();
