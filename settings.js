//------------------------------------------------------------------------------
// Settings
//------------------------------------------------------------------------------

export function getSettings() {
  return JSON.parse(localStorage.getItem('settings') || '{}');
}

export function setSettings(config) {
  localStorage.setItem('settings', JSON.stringify(settings));
}

// Displays an alert in the settings modal
function showSettingsAlert(msg, type) {
  const container = document.getElementById('settings-alert');

  const alertDiv = document.createElement('div');
  alertDiv.innerHTML = [
    `<div class="alert alert-${type} alert-dismissible" role="alert">`,
    `   <div>${msg}</div>`,
    '   <button type="button" class="btn-close" data-bs-dismiss="alert" aria-label="Close"></button>',
    '</div>',
  ].join('');

  container.classList.remove('d-none');
  container.classList.add('d-block');
  container.appendChild(alertDiv);
}

document.addEventListener('DOMContentLoaded', () => {
  // Load settings from local storage
  document.getElementById('settings-modal').addEventListener('show.bs.modal', (event) => {
    const settings = getSettings();
    document.getElementById('openai-api-key').value = settings.openaiApiKey || '';
  });

  // Save settings to local storage
  document.querySelector('#save-settings').addEventListener('click', function (event) {
    event.preventDefault();

    const openaiApiKey = document.getElementById('openai-api-key').value;

    const settings = {
      openaiApiKey: openaiApiKey,
    };

    setSettings(settings);

    showSettingsAlert('Settings saved!', 'success');
  });
});
