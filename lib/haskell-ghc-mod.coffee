GhcModiProcess = require './ghc-modi-process'
CompletionBackend = require './completion-backend'
{CompositeDisposable} = require 'atom'
ImportListView = require './views/import-list-view'

module.exports = HaskellGhcMod =
  process: null

  config:
    ghcModPath:
      type: 'string'
      default: 'ghc-mod'
      description: 'Path to ghc-mod'
    enableGhcModi:
      type: 'boolean'
      default: true
      description:
        'Using GHC Modi is suggested and noticeably faster,
         but if experiencing problems, disabling it can sometimes help.'
    ghcModiPath:
      type: 'string'
      default: 'ghc-modi'
      description: 'Path to ghc-modi. Only relevant for ghc-mod<5.4.0.0'
    debug:
      type: 'boolean'
      default: false
    additionalPathDirectories:
      type: 'array'
      default: []
      description: 'Add this directories to PATH when invoking ghc-mod.
                    You might want to add path to ghc here.
                    Separate with comma.'
      items:
        type: 'string'
    syncTimeout:
      type: 'integer'
      description: 'Some ghc-mod operations need to be run in sync. This option
                    sets timeout for such operations. Increase if getting
                    ETIMEDOUT errors.'
      default: 5000
      minimum: 100

    onSaveCheck:
      type: "boolean"
      default: true
      description: "Check file on save"

    onSaveLint:
      type: "boolean"
      default: true
      description: "Lint file on save"

    onChangeCheck:
      type: "boolean"
      default: false
      description: "Check file on change"

    onChangeLint:
      type: "boolean"
      default: false
      description: "Lint file on change"

    onMouseHoverShow:
      type: 'string'
      default: 'Info, fallback to Type'
      enum: ['Nothing', 'Type', 'Info', 'Info, fallback to Type']

    useLinter:
      type: 'boolean'
      default: false
      description: 'Use Atom Linter service for check and lint
                    (requires restart)'

  activate: (state) ->
    @process = new GhcModiProcess
    @disposables = null

  deactivate: ->
    @process?.destroy()
    @process = null
    @completionBackend = null
    @disposables?.dispose?()
    @disposables = null

  provideCompletionBackend: ->
    @completionBackend ?= new CompletionBackend @process
    @completionBackend

  consumeUPI: (service) ->
    upi = service.registerPlugin @disposables = new CompositeDisposable

    upi.setMessageTypes
      error: {}
      warning: {}
      lint: {}

    @disposables.add atom.commands.add 'atom-workspace',
      'haskell-ghc-mod:shutdown-backend': =>
        @process?.killProcess?()

    typeTooltip = =>
      @process.getTypeInBuffer(arguments...)
      .then ({range, type}) -> {range, text: type}
    infoTooltip = =>
      @process.getInfoInBuffer(arguments...)
      .then ({range, info}) -> {range, text: info}
    infoTypeTooltip = ->
      args = arguments
      infoTooltip(args...)
      .catch ->
        typeTooltip(args...)

    @disposables.add atom.commands.add 'atom-text-editor[data-grammar~="haskell"]',
      'haskell-ghc-mod:check-file': ({target}) =>
        editor = target.getModel()
        @process.doCheckBuffer(editor.getBuffer()).then (res) ->
          upi.setMessages res, ['error', 'warning']
      'haskell-ghc-mod:lint-file': ({target}) =>
        editor = target.getModel()
        @process.doLintBuffer(editor.getBuffer()).then (res) ->
          upi.setMessages res, ['lint']
      'haskell-ghc-mod:show-type': ({target, detail}) ->
        upi.showTooltip
          editor: target.getModel()
          detail: detail
          tooltip: (crange) ->
            typeTooltip target.getModel().getBuffer(), crange
      'haskell-ghc-mod:show-info': ({target, detail}) ->
        upi.showTooltip
          editor: target.getModel()
          detail: detail
          tooltip: (crange) ->
            infoTooltip target.getModel().getBuffer(), crange
      'haskell-ghc-mod:show-info-fallback-to-type': ({target, detail}) ->
        upi.showTooltip
          editor: target.getModel()
          detail: detail
          tooltip: (crange) ->
            infoTypeTooltip target.getModel().getBuffer(), crange
      'haskell-ghc-mod:insert-type': ({target, detail}) =>
        editor = target.getModel()
        upi.withEventRange {editor, detail}, ({crange}) =>
          @process.getTypeInBuffer(editor.getBuffer(), crange)
          .then ({range, type}) ->
            n = editor.indentationForBufferRow(range.start.row)
            indent = ' '.repeat n * editor.getTabLength()
            editor.scanInBufferRange /[\w'.]+/, range, ({matchText, stop}) ->
              symbol = matchText
              pos = [range.start.row, 0]
              editor.setTextInBufferRange [pos, pos],
                indent + symbol + " :: " + type + "\n"
              stop()
      'haskell-ghc-mod:insert-import': ({target, detail}) =>
        editor = target.getModel()
        buffer = editor.getBuffer()
        upi.withEventRange {editor, detail}, ({crange}) =>
          @process.findSymbolProvidersInBuffer buffer, crange, (lines) ->
            new ImportListView
              items: lines
              onConfirmed: (mod) ->
                pos = null
                indent = null
                buffer.backwardsScan /^(\s*)import/, ({match, range}) ->
                  r = buffer.rangeForRow range.start.row
                  pos = r.end
                  indent = match[1]
                pi = if pos?
                  {pos, indent}
                if pi?
                  editor.setTextInBufferRange [pi.pos, pi.pos], "\n#{pi.indent}import #{mod}"

    upi.onShouldShowTooltip (editor, crange) ->
      switch atom.config.get('haskell-ghc-mod.onMouseHoverShow')
        when 'Type'
          typeTooltip editor.getBuffer(), crange
        when 'Info'
          infoTooltip editor.getBuffer(), crange
        when 'Info, fallback to Type'
          infoTypeTooltip editor.getBuffer(), crange
        else
          Promise.reject ignore: true #this won't set backend status

    checkLint = (buffer, opt, fast) =>
      if atom.config.get("haskell-ghc-mod.on#{opt}Check") and
         atom.config.get("haskell-ghc-mod.on#{opt}Lint")
        @process.doCheckAndLint(buffer, fast).then (res) ->
          upi.setMessages res, ['error', 'warning', 'lint']
      else if atom.config.get("haskell-ghc-mod.on#{opt}Check")
        @process.doCheckBuffer(buffer, fast).then (res) ->
          upi.setMessages res, ['error', 'warning']
      else if atom.config.get("haskell-ghc-mod.on#{opt}Lint")
        @process.doLintBuffer(buffer, fast).then (res) ->
          upi.setMessages res, ['lint']

    @disposables.add upi.onDidSaveBuffer (buffer) ->
      checkLint buffer, 'Save'

    @disposables.add upi.onDidStopChanging (buffer) ->
      checkLint buffer, 'Change', true


    @disposables.add @process.onBackendActive ->
      upi.setStatus status: 'progress'

    @disposables.add @process.onBackendIdle ->
      upi.setStatus status: 'ready'

    @process.onBackendActive

    upi.setMenu 'Ghc-Mod', [
      {label: 'Check', command: 'haskell-ghc-mod:check-file'}
      {label: 'Lint', command: 'haskell-ghc-mod:lint-file'}
      {label: 'Stop Backend', command: 'haskell-ghc-mod:shutdown-backend'}
    ]

    @disposables.add atom.contextMenu.add
      'atom-text-editor[data-grammar~="haskell"]': [
        'label': 'Ghc-Mod'
        'submenu': [
            'label': 'Show Type'
            'command': 'haskell-ghc-mod:show-type'
          ,
            'label': 'Show Info'
            'command': 'haskell-ghc-mod:show-info'
          ,
            'label': 'Insert Type'
            'command': 'haskell-ghc-mod:insert-type'
          ,
            'label': 'Insert Import'
            'command': 'haskell-ghc-mod:insert-import'
        ]
      ]

    @disposables

  provideLinter: ->
    return unless atom.config.get 'haskell-ghc-mod.useLinter'
    [
      func: 'doCheckBuffer'
      lintOnFly: false
      scopes: ['source.haskell', 'text.tex.latex.haskell']
    ,
      func: 'doLintBuffer'
      lintOnFly: true
      scopes: ['source.haskell']
    ].map ({func, scopes, lintOnFly}) =>
      grammarScopes: scopes
      scope: 'file'
      lintOnFly: lintOnFly
      lint: (textEditor) =>
        return if textEditor.isEmpty()
        @process[func](textEditor.getBuffer(), lintOnFly).then (res) ->
          res.map ({uri, position, message, severity}) ->
            [message, messages...] = message.split /^(?!\s)/gm
            {
              type: severity
              text: message
              multiline: true
              filePath: uri
              range: [position, position.translate [0, 1]]
              trace: messages.map (text) ->
                type: 'trace'
                text: text
                multiline: true
            }
