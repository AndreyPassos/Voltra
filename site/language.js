(() => {
  const translations = {
    title: 'Voltra — Mixer de áudio para Mac | CaffeeeLabs',
    description: 'Voltra é um mixer gratuito para macOS. Ajuste o volume dos aplicativos, escolha saídas de áudio e salve seus perfis.',
    home: 'Voltra, início',
    language: 'Idioma',
    source: 'Código no GitHub',
    heroFirst: 'O som do seu Mac,',
    heroSecond: 'do seu jeito.',
    lead: 'Ajuste o volume de cada aplicativo, troque de saída e organize seus perfis de áudio em um só lugar.',
    download: 'Baixar Voltra para Mac',
    spec: 'Gratuito · Apple Silicon · macOS 14.2 ou posterior',
    installLink: 'Como instalar',
    master: 'Volume geral',
    music: 'Música',
    browser: 'Navegador',
    output: 'Saída de áudio',
    speakers: 'Alto-falantes do Mac',
    caption: 'Ilustração do mixer na barra de menus',
    features: 'Funcionalidades',
    volumeTitle: 'Volume por app',
    volumeBody: 'Ajuste ou silencie aplicativos ativos pela barra de menus. Em chamadas detectadas, use o volume geral.',
    devicesTitle: 'Troca de dispositivos',
    devicesBody: 'Escolha a entrada e a saída e alterne automaticamente quando um dispositivo preferido se conectar.',
    profilesTitle: 'Perfis e automações',
    profilesBody: 'Salve seus ajustes e aplique perfis ao abrir um app, conectar um dispositivo ou chegar a um horário.',
    installTitle: 'Instalação',
    stepOpen: 'Abra o DMG e arraste o Voltra para a pasta Aplicativos.',
    stepBlocked: 'Se o macOS bloquear a primeira abertura, veja as',
    appleHelp: 'instruções da Apple',
    notarization: 'A Apple ainda não notarizou este pacote de desenvolvimento.',
    stepPermission: 'Para usar o mixer por aplicativo, permita a gravação de áudio do sistema quando o macOS solicitar.',
    checksum: 'Ver SHA-256 do instalador',
    supportTitle: 'Apoie o Voltra',
    supportBody: 'O download é gratuito. Se o Voltra for útil no seu dia a dia, você pode apoiar seu desenvolvimento com um café.',
    supportAction: 'Me pague um café',
    supportQR: 'Escaneie o QR code ou abra o perfil no Buy Me a Coffee',
    credit: 'Voltra, um projeto da',
  };

  const selector = document.querySelector('.language select');
  const description = document.querySelector('meta[name="description"]');
  const help = document.querySelector('[data-help]');
  const officialButton = document.querySelector('.support-links .bmc-btn');
  if (officialButton) {
    officialButton.rel = 'noopener noreferrer';
    const label = officialButton.querySelector('.bmc-btn-text');
    if (label) label.dataset.text = 'supportAction';
    document.querySelector('.support-fallback').hidden = true;
  }
  const strings = [
    ...Array.from(document.querySelectorAll('[data-text]'), node => ({
      key: node.dataset.text,
      english: node.textContent,
      write: value => { node.textContent = value; },
    })),
    ...Array.from(document.querySelectorAll('[data-label]'), node => ({
      key: node.dataset.label,
      english: node.getAttribute('aria-label'),
      write: value => node.setAttribute('aria-label', value),
    })),
    { key: 'title', english: document.title, write: value => { document.title = value; } },
    { key: 'description', english: description.content, write: value => { description.content = value; } },
  ];

  function applyLanguage(language) {
    selector.value = language;
    document.documentElement.lang = language === 'pt' ? 'pt-BR' : 'en';
    for (const { key, english, write } of strings) {
      write(language === 'pt' ? translations[key] ?? english : english);
    }
    help.href = language === 'pt'
      ? 'https://support.apple.com/pt-br/102445'
      : 'https://support.apple.com/en-us/102445';
  }

  const preferenceKey = 'voltra-language';
  let saved;
  try { saved = localStorage.getItem(preferenceKey); } catch { /* Storage can be blocked. */ }
  const browserLanguage = navigator.languages?.[0] || navigator.language || '';
  const detected = /^pt(?:-|$)/i.test(browserLanguage) ? 'pt' : 'en';
  applyLanguage(saved === 'en' || saved === 'pt' ? saved : detected);
  selector.closest('.language').hidden = false;

  selector.addEventListener('change', () => {
    applyLanguage(selector.value);
    try { localStorage.setItem(preferenceKey, selector.value); } catch { /* Keep the in-page selection. */ }
  });
})();
