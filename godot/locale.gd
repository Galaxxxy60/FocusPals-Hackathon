extends RefCounted
## Central localization file for FocusPals UI.
## Usage:  var L := preload("res://locale.gd").new()
##         L.set_lang("en")
##         label.text = L.t("settings_title")

var _lang := "en"
var _strings := {}

func _init() -> void:
	_build_strings()

func set_lang(lang_code: String) -> void:
	_lang = lang_code if lang_code in ["fr", "en", "ja", "zh"] else "en"

func t(key: String) -> String:
	## Returns the translated string for the given key, or the key itself as fallback.
	if _strings.has(key):
		var entry: Dictionary = _strings[key]
		if entry.has(_lang):
			return entry[_lang]
		return entry.get("en", key)
	return key

func _build_strings() -> void:
	_strings = {
		# ── Panel title ──
		"settings_title": {
			"fr": "⚙️  Réglages",
			"en": "⚙️  Settings",
			"ja": "⚙️  設定",
			"zh": "⚙️  设置",
		},

		# ── Section headers ──
		"section_session": {
			"fr": "⏱️  Session",
			"en": "⏱️  Session",
			"ja": "⏱️  セッション",
			"zh": "⏱️  会话",
		},
		"section_audio": {
			"fr": "🎤  Audio",
			"en": "🎤  Audio",
			"ja": "🎤  オーディオ",
			"zh": "🎤  音频",
		},
		"section_api": {
			"fr": "🔑  API",
			"en": "🔑  API",
			"ja": "🔑  API",
			"zh": "🔑  API",
		},
		"section_general": {
			"fr": "🌐  Général",
			"en": "🌐  General",
			"ja": "🌐  一般",
			"zh": "🌐  通用",
		},
		"section_permissions": {
			"fr": "🔒  Permissions",
			"en": "🔒  Permissions",
			"ja": "🔒  権限",
			"zh": "🔒  权限",
		},

		# ── Session ──
		"deep_work_duration": {
			"fr": "Durée du Deep Work",
			"en": "Deep Work Duration",
			"ja": "ディープワークの時間",
			"zh": "深度工作时长",
		},

		# ── Audio ──
		"microphone": {
			"fr": "Microphone",
			"en": "Microphone",
			"ja": "マイク",
			"zh": "麦克风",
		},
		"volume_tama": {
			"fr": "Volume Tama",
			"en": "Tama Volume",
			"ja": "Tamaの音量",
			"zh": "Tama 音量",
		},
		"test_mic_tooltip": {
			"fr": "Tester ce micro",
			"en": "Test this mic",
			"ja": "このマイクをテスト",
			"zh": "测试此麦克风",
		},
		"mic_active": {
			"fr": "ACTIF",
			"en": "ACTIVE",
			"ja": "使用中",
			"zh": "已启用",
		},

		# ── API ──
		"api_key_label": {
			"fr": "Clé API Gemini",
			"en": "Gemini API Key",
			"ja": "Gemini APIキー",
			"zh": "Gemini API 密钥",
		},
		"api_key_placeholder": {
			"fr": "Collez votre clé API...",
			"en": "Paste your API key...",
			"ja": "APIキーを貼り付け...",
			"zh": "粘贴您的API密钥...",
		},
		"api_usage_label": {
			"fr": "Utilisation",
			"en": "Usage",
			"ja": "使用状況",
			"zh": "使用情况",
		},
		"api_since_launch": {
			"fr": "Depuis le lancement",
			"en": "Since launch",
			"ja": "起動してから",
			"zh": "自启动以来",
		},
		"api_status_checking": {
			"fr": "⏳ Vérification en cours...",
			"en": "⏳ Verifying...",
			"ja": "⏳ 確認中...",
			"zh": "⏳ 验证中...",
		},
		"api_status_valid": {
			"fr": "✅ Clé valide",
			"en": "✅ Key valid",
			"ja": "✅ キー有効",
			"zh": "✅ 密钥有效",
		},
		"api_status_invalid": {
			"fr": "❌ Clé invalide",
			"en": "❌ Invalid key",
			"ja": "❌ 無効なキー",
			"zh": "❌ 密钥无效",
		},
		"api_status_required": {
			"fr": "⚠️ Clé requise pour démarrer",
			"en": "⚠️ API key required to start",
			"ja": "⚠️ 開始するにはAPIキーが必要",
			"zh": "⚠️ 需要API密钥才能启动",
		},

		# ── API Usage stats ──
		"usage_connections": {
			"fr": "Connexions",
			"en": "Connections",
			"ja": "接続",
			"zh": "连接",
		},
		"usage_time": {
			"fr": "Temps",
			"en": "Time",
			"ja": "時間",
			"zh": "时间",
		},
		"usage_scans": {
			"fr": "Scans",
			"en": "Scans",
			"ja": "スキャン",
			"zh": "扫描",
		},

		# ── General ──
		"language_label": {
			"fr": "Langue / Language",
			"en": "Language / Langue",
			"ja": "言語 / Language",
			"zh": "语言 / Language",
		},
		"tama_size": {
			"fr": "Taille de Tama",
			"en": "Tama Size",
			"ja": "Tamaのサイズ",
			"zh": "Tama 大小",
		},

		# ── Permissions ──
		"screen_share_title": {
			"fr": "🖥️  Partage d'écran",
			"en": "🖥️  Screen Share",
			"ja": "🖥️  画面共有",
			"zh": "🖥️  屏幕共享",
		},
		"screen_share_desc": {
			"fr": "Tama voit votre écran",
			"en": "Tama can see your screen",
			"ja": "Tamaがあなたの画面を見ます",
			"zh": "Tama 可以看到您的屏幕",
		},
		"mic_permission_title": {
			"fr": "🎤  Microphone",
			"en": "🎤  Microphone",
			"ja": "🎤  マイク",
			"zh": "🎤  麦克风",
		},
		"mic_permission_desc": {
			"fr": "Tama vous entend",
			"en": "Tama can hear you",
			"ja": "Tamaがあなたの声を聞きます",
			"zh": "Tama 可以听到您的声音",
		},

		# ── Radial Menu ──
		"radial_settings": {
			"fr": "Réglages",
			"en": "Settings",
			"ja": "設定",
			"zh": "设置",
		},
		"radial_talk": {
			"fr": "Parler",
			"en": "Talk",
			"ja": "会話",
			"zh": "对话",
		},
		"radial_session": {
			"fr": "Session",
			"en": "Work Session",
			"ja": "作業セッション",
			"zh": "工作会话",
		},
		"radial_quit": {
			"fr": "Quitter",
			"en": "Quit",
			"ja": "終了",
			"zh": "退出",
		},
	}
