/**
 * RA CYF - WebAR com 8th Wall Engine (self-hosted / open source).
 *
 * Cada imagem em image-targets/ vira um alvo rastreavel; ao ser reconhecida, o video
 * correspondente e projetado exatamente sobre o poster.
 *
 * Fluxo:
 *   manifest.json -> <nome>.json (um por alvo) -> XR8.XrController.configure({imageTargetData})
 *
 * O engine rastreia ate 32 alvos simultaneos, entao os 18 ficam ativos ao mesmo tempo e
 * nao e preciso trocar conjuntos em runtime.
 */
;(function () {
  'use strict'

  var TARGETS_DIR = 'image-targets'
  var FADE_MS = 450

  // ---------------------------------------------------------------- carregamento

  // Carregado uma vez e compartilhado entre a config do XR8 e a montagem da cena.
  var targetsPromise = fetch(TARGETS_DIR + '/manifest.json', {cache: 'no-cache'})
    .then(function (res) {
      if (!res.ok) throw new Error('manifest.json: HTTP ' + res.status)
      return res.json()
    })
    .then(function (manifest) {
      var list = (manifest && manifest.targets) || []
      if (!list.length) throw new Error('manifest.json nao lista nenhum alvo.')
      return Promise.all(list.map(function (entry) {
        return fetch(TARGETS_DIR + '/' + entry.name + '.json', {cache: 'no-cache'})
          .then(function (res) {
            if (!res.ok) throw new Error(entry.name + '.json: HTTP ' + res.status)
            return res.json()
          })
          .then(function (target) {
            // imagePath e consumido pelo engine como URL. Deixar relativo daria margem a
            // ele resolver contra a raiz do dominio, o que quebraria em hospedagens sob
            // subcaminho (ex.: GitHub Pages em /repo/). Resolvemos aqui e nao ha duvida.
            target.imagePath = new URL(target.imagePath, document.baseURI).href
            return target
          })
      }))
    })

  targetsPromise.catch(function (err) { fatal(err) })

  function fatal(err) {
    console.error('[RA CYF]', err)
    var box = document.getElementById('fatal')
    var msg = document.getElementById('fatal-msg')
    if (box && msg) {
      msg.textContent = 'Não foi possível carregar a experiência: ' + err.message
      box.hidden = false
    }
  }

  // ---------------------------------------------------------------- estado do som

  // Um unico video toca com som por vez: o do alvo reconhecido mais recentemente.
  var soundOn = false
  var soundHolder = null   // componente ar-video-plane que detem o audio

  function grantSound(component) {
    if (soundHolder && soundHolder !== component) soundHolder.setMuted(true)
    soundHolder = component
    component.setMuted(!soundOn)
  }

  function releaseSound(component) {
    if (soundHolder === component) soundHolder = null
  }

  // ---------------------------------------------------------------- HUD

  var tracked = Object.create(null)   // alvos visiveis neste momento

  function setTracked(name, isVisible) {
    if (isVisible) tracked[name] = true
    else delete tracked[name]

    var hint = document.getElementById('scan-hint')
    if (hint) hint.classList.toggle('is-hidden', Object.keys(tracked).length > 0)
  }

  // ---------------------------------------------------------------- componente AR

  /**
   * Projeta um video sobre o image target do elemento pai.
   *
   * Precisa ser filho de uma entidade com `xrextras-named-image-target`, que emite
   * `xrextrasimagegeometry` (dimensoes do alvo), `xrextrasfound` e `xrextraslost`.
   */
  AFRAME.registerComponent('ar-video-plane', {
    schema: {
      video: {type: 'selector'},
    },

    init: function () {
      var self = this
      var parent = this.el.parentNode

      this.video = this.data.video
      this.mesh = null
      this.opacity = 0
      this.visible = false
      this.started = false

      this.onGeometry = function (evt) { self.buildMesh(evt.detail) }
      this.onFound = function () { self.show() }
      this.onLost = function () { self.hide() }

      parent.addEventListener('xrextrasimagegeometry', this.onGeometry)
      parent.addEventListener('xrextrasfound', this.onFound)
      parent.addEventListener('xrextraslost', this.onLost)
    },

    remove: function () {
      var parent = this.el.parentNode
      if (parent) {
        parent.removeEventListener('xrextrasimagegeometry', this.onGeometry)
        parent.removeEventListener('xrextrasfound', this.onFound)
        parent.removeEventListener('xrextraslost', this.onLost)
      }
      releaseSound(this)
    },

    buildMesh: function (geometry) {
      if (this.mesh) return

      // Malha derivada da geometria real do alvo: como o crop cobre a imagem inteira,
      // o plano bate pixel a pixel com o poster impresso.
      var geo = XRExtras.ThreeExtras.createTargetGeometry(geometry, false)
      if (!geo) {
        console.warn('[RA CYF] geometria de alvo nao suportada:', geometry && geometry.type)
        return
      }

      var texture = new THREE.VideoTexture(this.video)
      texture.minFilter = THREE.LinearFilter
      texture.magFilter = THREE.LinearFilter
      texture.generateMipmaps = false
      // Sem isso o video sai lavado sob colorManagement.
      if ('colorSpace' in texture) texture.colorSpace = THREE.SRGBColorSpace

      var material = new THREE.MeshBasicMaterial({
        map: texture,
        transparent: true,
        opacity: 0,
        toneMapped: false,
      })

      this.mesh = new THREE.Mesh(geo, material)
      this.el.setObject3D('mesh', this.mesh)
    },

    show: function () {
      this.visible = true
      setTracked(this.el.dataset.targetName, true)
      grantSound(this)

      var video = this.video

      // preload="none" ate aqui: o download so comeca quando o alvo aparece de fato.
      if (!this.started) {
        this.started = true
        if (!video.src) video.src = video.dataset.src
      }

      var playing = video.play()
      if (playing && playing.catch) {
        playing.catch(function (err) {
          // Se o som estava ligado, o navegador pode recusar. Cai para mudo e tenta de novo.
          if (!video.muted) {
            video.muted = true
            video.play().catch(function (e) { console.warn('[RA CYF] play falhou:', e) })
          } else {
            console.warn('[RA CYF] play falhou:', err)
          }
        })
      }
    },

    hide: function () {
      this.visible = false
      setTracked(this.el.dataset.targetName, false)
      this.video.pause()
      releaseSound(this)
      // O pai ja fica invisivel no `lost`, entao zera direto em vez de animar.
      this.opacity = 0
      if (this.mesh) this.mesh.material.opacity = 0
    },

    setMuted: function (muted) {
      this.video.muted = muted
    },

    tick: function (time, delta) {
      if (!this.mesh || !this.visible) return
      if (this.opacity >= 1) return

      // Fade-in curto para o corte poster -> video nao piscar.
      this.opacity = Math.min(1, this.opacity + (delta || 16) / FADE_MS)
      this.mesh.material.opacity = this.opacity
    },
  })

  // ---------------------------------------------------------------- montagem da cena

  function buildScene(targets) {
    var pool = document.getElementById('video-pool')
    var root = document.getElementById('targets')

    targets.forEach(function (target) {
      var src = target.metadata && target.metadata.video
      if (!src) {
        console.warn('[RA CYF] alvo "' + target.name + '" sem video no metadata; ignorado.')
        return
      }

      var video = document.createElement('video')
      video.id = 'video-' + target.name
      video.dataset.src = src          // src real so e atribuido no primeiro reconhecimento
      video.loop = true
      video.muted = true
      video.playsInline = true
      video.preload = 'none'
      video.crossOrigin = 'anonymous'
      video.setAttribute('playsinline', '')
      video.setAttribute('webkit-playsinline', '')
      video.addEventListener('error', function () {
        console.error('[RA CYF] falha ao carregar ' + src)
      })
      pool.appendChild(video)

      var anchor = document.createElement('a-entity')
      anchor.setAttribute('xrextras-named-image-target', 'name: ' + target.name)

      var plane = document.createElement('a-entity')
      plane.dataset.targetName = target.name
      plane.setAttribute('ar-video-plane', 'video: #' + video.id)

      anchor.appendChild(plane)
      root.appendChild(anchor)
    })

    console.log('[RA CYF] ' + targets.length + ' alvos montados.')
  }

  // ---------------------------------------------------------------- botao de som

  function initSoundButton() {
    var btn = document.getElementById('sound-btn')
    if (!btn) return

    btn.hidden = false
    btn.addEventListener('click', function () {
      soundOn = !soundOn
      btn.classList.toggle('is-on', soundOn)
      btn.querySelector('.sound-label').textContent = soundOn ? 'Som ligado' : 'Toque para o som'

      // Desmutar precisa acontecer dentro do gesto do usuario.
      if (soundHolder) {
        soundHolder.setMuted(!soundOn)
        if (soundOn) {
          var p = soundHolder.video.play()
          if (p && p.catch) p.catch(function () {})
        }
      }
    })
  }

  // ---------------------------------------------------------------- boot

  document.addEventListener('DOMContentLoaded', function () {
    targetsPromise.then(function (targets) {
      buildScene(targets)
      initSoundButton()
    }).catch(function () { /* ja tratado em fatal() */ })
  })

  /**
   * Registra os componentes A-Frame do engine.
   *
   * O 8th Wall hospedado (apps.8thwall.com/xrweb) registrava 'xrweb' sozinho ao carregar.
   * A distribuicao self-hosted nao faz isso: ela apenas expoe as fabricas em XR8.AFrame e
   * espera que a aplicacao registre. Sem isto, <a-scene xrweb> vira um atributo inerte -
   * o A-Frame ignora componentes desconhecidos sem reclamar -, XR8.run() nunca roda, e a
   * tela de carregamento gira eternamente esperando uma textura de camera que nao vem.
   */
  function registerEngineComponents() {
    if (!window.AFRAME || !window.XR8 || !XR8.AFrame) return false

    if (!AFRAME.components.xrweb) {
      AFRAME.registerComponent('xrconfig', XR8.AFrame.xrconfigComponent())
      AFRAME.registerComponent('xrweb', XR8.AFrame.xrwebComponent())
      AFRAME.registerComponent('xrface', XR8.AFrame.xrfaceComponent())
    }

    if (window.XRExtras && XRExtras.AFrame) {
      XRExtras.AFrame.registerXrExtrasComponents()
    }

    return true
  }

  // A cena ja existia no DOM quando 'xrweb' ainda nao era um componente conhecido, entao
  // o A-Frame nunca o instanciou. Reaplicar o atributo agora o forca a inicializar.
  function activateScene() {
    var scene = document.querySelector('a-scene')
    if (!scene) return
    var config = scene.getAttribute('xrweb') || 'disableWorldTracking: true'
    if (typeof config !== 'string') config = 'disableWorldTracking: true'
    scene.removeAttribute('xrweb')
    scene.setAttribute('xrweb', config)
    console.log('[RA CYF] xrweb ativado.')
  }

  function onXrLoaded() {
    try {
      if (!registerEngineComponents()) {
        throw new Error('XR8.AFrame indisponivel apos o carregamento do engine.')
      }
    } catch (err) {
      fatal(err)
      return
    }

    targetsPromise.then(function (targets) {
      // Substitui o conjunto ativo de alvos pelo nosso.
      XR8.XrController.configure({imageTargetData: targets})
      console.log('[RA CYF] engine configurado com ' + targets.length + ' image targets.')
      activateScene()
    }).catch(function () { /* ja tratado em fatal() */ })
  }

  // Rede de seguranca: se a camera nao iniciar, mostra o motivo em vez de girar para sempre.
  var started = false
  window.addEventListener('camerastatuschange', function (evt) {
    if (evt.detail && evt.detail.status === 'hasStream') started = true
  })
  setTimeout(function () {
    if (started) return
    var reasons = []
    if (!window.XR8) reasons.push('o engine (XR8) nao carregou - verifique a rede ou um bloqueador')
    else if (!AFRAME.components.xrweb) reasons.push('o componente xrweb nao foi registrado')
    else reasons.push('a camera nao iniciou - permissao negada ou indisponivel')
    fatal(new Error(reasons.join('; ')))
  }, 20000)

  if (window.XR8) onXrLoaded()
  else window.addEventListener('xrloaded', onXrLoaded)
})()
