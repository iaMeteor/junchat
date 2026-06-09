#!/usr/bin/env ruby

require "json"

app_path = ARGV.fetch(0)

unless Dir.exist?(app_path)
  exit 0
end

ZH_HANS_PATCH = {
  "common" => {
    "back" => "返回",
    "next" => "下一步",
    "options" => "选项",
    "preferences" => "偏好",
    "reaction" => "回应",
    "reactions" => "回应",
    "reconnecting" => "正在重新连接..."
  },
  "handset" => {
    "overlay_back_button" => "返回扬声器模式",
    "overlay_description" => "仅在使用 App 时生效",
    "overlay_title" => "听筒模式"
  },
  "settings" => {
    "audio_tab" => {
      "effect_volume_description" => "调整回应和举手效果的播放音量。",
      "effect_volume_label" => "音效音量"
    },
    "background_blur_header" => "背景",
    "background_blur_label" => "模糊视频背景",
    "blur_not_supported_by_browser" => "此设备不支持背景模糊。",
    "developer_tab_title" => "开发者",
    "devices" => {
      "camera" => "摄像头",
      "camera_numbered" => "摄像头 {{n}}",
      "change_device_button" => "切换音频设备",
      "default" => "默认",
      "default_named" => "默认 <2>({{name}})</2>",
      "handset" => "听筒",
      "loudspeaker" => "扬声器",
      "microphone" => "麦克风",
      "microphone_numbered" => "麦克风 {{n}}",
      "speaker" => "扬声器",
      "speaker_numbered" => "扬声器 {{n}}"
    },
    "feedback_tab_body" => "如果你遇到问题或想提供反馈，请在下方发送简短说明。",
    "feedback_tab_description_label" => "你的反馈",
    "feedback_tab_h4" => "提交反馈",
    "feedback_tab_send_logs_label" => "包含调试日志",
    "feedback_tab_thank_you" => "感谢，我们已收到你的反馈。",
    "feedback_tab_title" => "反馈",
    "opt_in_description" => "<0></0><1></1>你可以取消勾选此项来撤回同意。如果你当前正在通话，此设置会在通话结束后生效。",
    "preferences_tab" => {
      "developer_mode_label" => "开发者模式",
      "developer_mode_label_description" => "启用开发者模式并显示开发者设置标签。",
      "introduction" => "你可以在这里配置更多选项，改善通话体验。",
      "reactions_play_sound_description" => "通话中有人发送回应时播放音效。",
      "reactions_play_sound_label" => "播放回应音效",
      "reactions_show_description" => "通话中有人发送回应时显示动画。",
      "reactions_show_label" => "显示回应",
      "show_hand_raised_timer_description" => "参与者举手时显示计时器。",
      "show_hand_raised_timer_label" => "显示举手时长"
    }
  },
  "video_tile" => {
    "always_show" => "始终显示",
    "call_ended" => "通话已结束",
    "calling" => "正在呼叫...",
    "camera_starting" => "视频加载中...",
    "collapse" => "收起",
    "expand" => "展开",
    "mute_for_me" => "为我静音",
    "muted_for_me" => "已为我静音",
    "screen_share_volume" => "屏幕共享音量",
    "volume" => "音量",
    "waiting_for_media" => "正在等待媒体..."
  }
}.freeze

ZH_HANT_PATCH = {
  "common" => {
    "analytics" => "分析",
    "back" => "返回",
    "next" => "下一步",
    "options" => "選項",
    "preferences" => "偏好",
    "reaction" => "回應",
    "reactions" => "回應",
    "reconnecting" => "正在重新連線..."
  },
  "handset" => {
    "overlay_back_button" => "返回揚聲器模式",
    "overlay_description" => "僅在使用 App 時生效",
    "overlay_title" => "聽筒模式"
  },
  "settings" => {
    "audio_tab" => {
      "effect_volume_description" => "調整回應和舉手效果的播放音量。",
      "effect_volume_label" => "音效音量"
    },
    "background_blur_header" => "背景",
    "background_blur_label" => "模糊視訊背景",
    "blur_not_supported_by_browser" => "此裝置不支援背景模糊。",
    "developer_tab_title" => "開發者",
    "devices" => {
      "camera" => "相機",
      "camera_numbered" => "相機 {{n}}",
      "change_device_button" => "切換語音裝置",
      "default" => "預設",
      "default_named" => "預設 <2>({{name}})</2>",
      "handset" => "聽筒",
      "loudspeaker" => "揚聲器",
      "microphone" => "麥克風",
      "microphone_numbered" => "麥克風 {{n}}",
      "speaker" => "揚聲器",
      "speaker_numbered" => "揚聲器 {{n}}"
    },
    "feedback_tab_body" => "若你遇到問題或想提供回饋，請在下方傳送簡短說明。",
    "feedback_tab_description_label" => "你的回饋",
    "feedback_tab_h4" => "提交回饋",
    "feedback_tab_send_logs_label" => "包含除錯紀錄",
    "feedback_tab_thank_you" => "感謝，我們已收到你的回饋。",
    "feedback_tab_title" => "回饋",
    "opt_in_description" => "<0></0><1></1>你可以取消勾選此項來撤回同意。如果你目前正在通話，此設定會在通話結束後生效。",
    "preferences_tab" => {
      "developer_mode_label" => "開發者模式",
      "developer_mode_label_description" => "啟用開發者模式並顯示開發者設定分頁。",
      "introduction" => "你可以在這裡設定更多選項，改善通話體驗。",
      "reactions_play_sound_description" => "通話中有人傳送回應時播放音效。",
      "reactions_play_sound_label" => "播放回應音效",
      "reactions_show_description" => "通話中有人傳送回應時顯示動畫。",
      "reactions_show_label" => "顯示回應",
      "show_hand_raised_timer_description" => "參與者舉手時顯示計時器。",
      "show_hand_raised_timer_label" => "顯示舉手時長"
    }
  },
  "video_tile" => {
    "always_show" => "一律顯示",
    "call_ended" => "通話已結束",
    "calling" => "正在呼叫...",
    "camera_starting" => "視訊載入中...",
    "collapse" => "收起",
    "expand" => "展開",
    "mute_for_me" => "為我靜音",
    "muted_for_me" => "已為我靜音",
    "screen_share_volume" => "螢幕分享音量",
    "volume" => "音量",
    "waiting_for_media" => "正在等待媒體..."
  }
}.freeze

def deep_merge(target, patch)
  patch.each do |key, value|
    if value.is_a?(Hash) && target[key].is_a?(Hash)
      deep_merge(target[key], value)
    else
      target[key] = value
    end
  end
  target
end

patches = {
  /zh-Hans-app-.*\.json$/ => ZH_HANS_PATCH,
  /zh-Hant-app-.*\.json$/ => ZH_HANT_PATCH,
  /en-app-.*\.json$/ => ZH_HANS_PATCH
}

Dir.glob(File.join(app_path, "**", "EmbeddedElementCall_EmbeddedElementCall.bundle", "dist", "assets", "*-app-*.json")).each do |path|
  patch = patches.find { |pattern, _| File.basename(path).match?(pattern) }&.last
  next unless patch

  data = JSON.parse(File.read(path))
  deep_merge(data, patch)
  File.write(path, JSON.pretty_generate(data))
end
