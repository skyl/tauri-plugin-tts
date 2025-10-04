package space.httpjames.tauri_plugin_tts

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import android.webkit.WebView
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import java.util.Locale
import java.util.UUID
import kotlin.math.abs
import kotlin.math.ln

// --------------------------- Rate mapping ---------------------------

/**
 * Map Corpán's web-style rate (≈0.1–1.5, with 1.0 = "normal") to Android's engine-relative rate.
 * We use a gentle log scale and cap to ~2.5–3.0x for the fast end (engine-dependent).
 */
private fun mapWebRateToAndroid(
  webRate: Float,
  targetMax: Float = 3.0f
): Float {
  val W_MIN = 0.10f
  val W_DEF = 1.00f
  val W_MAX = 1.50f

  val A_MIN = 0.10f
  val A_DEF = 1.00f
  val A_MAX = targetMax

  val pad = 0.02f * (A_MAX - A_MIN)
  val lo = A_MIN + pad
  val hi = A_MAX - pad

  val w = webRate.coerceIn(W_MIN, W_MAX)
  if (abs(w - W_DEF) < 1e-6f) return A_DEF

  return if (w < W_DEF) {
    // [0.1..1.0) → [lo..A_DEF] (log scale)
    val progress = (ln((w / W_MIN).toDouble()) / ln((W_DEF / W_MIN).toDouble())).toFloat()
    lo + progress * (A_DEF - lo)
  } else {
    // (1.0..1.5] → [A_DEF..hi] (log scale)
    val progress = (ln((w / W_DEF).toDouble()) / ln((W_MAX / W_DEF).toDouble())).toFloat()
    A_DEF + progress * (hi - A_DEF)
  }
}

// --------------------------- Invoke args ---------------------------

@InvokeArg
internal class SpeakArgs {
  lateinit var text: String
  var language: String? = null    // BCP-47 (e.g., "fa-IR")
  var rate: Float? = null         // 0.1–1.5
  var voiceId: String? = null     // Voice.getName()
}

// --------------------------- Plugin ---------------------------

@TauriPlugin
class ExamplePlugin(private val activity: Activity) : Plugin(activity) {

  private var tts: TextToSpeech? = null
  private var isInitialized = false
  private val pendingActions = mutableListOf<() -> Unit>()

  override fun load(webView: WebView) {
    initializeTTS()
  }

  private fun initializeTTS() {
    if (tts != null) return
    tts = TextToSpeech(activity) { status ->
      isInitialized = (status == TextToSpeech.SUCCESS)
      val event = JSObject()
      if (isInitialized) {
        // Leave engine default language as-is; we pick per-utterance
        event.put("initialized", true)
        trigger("ttsInitialized", event)
        drainPending()
      } else {
        event.put("error", "Failed to initialize TTS")
        trigger("ttsError", event)
      }
    }
  }

  private fun ensureReady(action: () -> Unit) {
    if (isInitialized && tts != null) {
      action()
    } else {
      pendingActions.add(action)
      initializeTTS()
    }
  }

  private fun drainPending() {
    val actions = ArrayList(pendingActions)
    pendingActions.clear()
    actions.forEach { it.invoke() }
  }

  // --------------------------- Helpers ---------------------------

  private fun baseLang(tag: String?): String? {
    if (tag.isNullOrBlank()) return null
    val t = tag.lowercase(Locale.ROOT)
    val i = t.indexOf('-')
    return if (i == -1) t else t.substring(0, i)
  }

  private fun localeMatches(voice: Voice, langTag: String?): Int {
    if (langTag.isNullOrBlank()) return 0
    val wantLc = langTag.lowercase(Locale.ROOT)
    val base = baseLang(wantLc)
    val vTag = voice.locale?.toLanguageTag()?.lowercase(Locale.ROOT) ?: return 0
    return when {
      vTag == wantLc -> 3
      base != null && (vTag == base || vTag.startsWith("$base-")) -> 2
      else -> 0
    }
  }

  private fun chooseBestVoiceForLanguage(tts: TextToSpeech, langTag: String): Voice? {
    val voices = tts.voices ?: return null

    // Prefer: locale match (exact > base), offline (no network), higher quality, lower latency.
    return voices
      .filter { it != null }
      .sortedWith(
        compareByDescending<Voice> { localeMatches(it, langTag) } // 3/2/0
          .thenBy { it.isNetworkConnectionRequired }              // false (offline) first
          .thenByDescending { it.quality }                        // higher is better
          .thenBy { it.latency }                                  // lower is better
          .thenBy { it.name }                                     // stable tiebreaker
      )
      .firstOrNull()
  }

  private fun findVoiceById(tts: TextToSpeech, voiceId: String): Voice? {
    val voices = tts.voices ?: return null
    return voices.firstOrNull { it.name == voiceId }
  }

  private fun currentEngine(tts: TextToSpeech?): String? {
    return try {
      tts?.defaultEngine
    } catch (_: Throwable) {
      null
    }
  }

  // --------------------------- Commands ---------------------------

  @Command
  fun speak(invoke: Invoke) {
    val args = try {
      invoke.parseArgs(SpeakArgs::class.java)
    } catch (e: Exception) {
      invoke.reject("Invalid args: ${e.message}")
      return
    }

    ensureReady {
      val t = tts
      if (t == null) {
        invoke.reject("TTS not initialized")
        return@ensureReady
      }

      try {
        // Voice selection (prefer explicit voiceId; otherwise pick best for language)
        val chosenVoice: Voice? = when {
          !args.voiceId.isNullOrBlank() -> findVoiceById(t, args.voiceId!!)
          !args.language.isNullOrBlank() -> chooseBestVoiceForLanguage(t, args.language!!)
          else -> null
        }

        if (chosenVoice != null) {
          // Reject network-only voices for offline-first product
          if (chosenVoice.isNetworkConnectionRequired) {
            invoke.reject("Requested voice requires network: ${chosenVoice.name}")
            return@ensureReady
          }
          if (Build.VERSION.SDK_INT >= 21) {
            val setOk = t.setVoice(chosenVoice)
            if (setOk != TextToSpeech.SUCCESS) {
              invoke.reject("Failed to set voice: ${chosenVoice.name}")
              return@ensureReady
            }
          }
        } else if (!args.language.isNullOrBlank()) {
          val res = t.setLanguage(Locale.forLanguageTag(args.language))
          if (res == TextToSpeech.LANG_MISSING_DATA || res == TextToSpeech.LANG_NOT_SUPPORTED) {
            invoke.reject("Language not supported or missing data: ${args.language}")
            return@ensureReady
          }
        }

        // Rate
        val androidRate = mapWebRateToAndroid(args.rate ?: 1.0f, targetMax = 3.0f)
        t.setSpeechRate(androidRate)

        // Speak
        val utteranceId = UUID.randomUUID().toString()
        t.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
          override fun onStart(utteranceId: String?) {
            val event = JSObject()
            event.put("status", "started")
            trigger("ttsStatus", event)
          }

          override fun onDone(utteranceId: String?) {
            invoke.resolve()
          }

          @Deprecated("Deprecated in Java")
          override fun onError(utteranceId: String?) {
            invoke.reject("Speech failed")
          }

          override fun onError(utteranceId: String?, errorCode: Int) {
            invoke.reject("Speech failed: $errorCode")
          }
        })

        val res = t.speak(args.text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
        if (res == TextToSpeech.ERROR) {
          invoke.reject("Failed to queue speech")
        }
      } catch (e: Exception) {
        invoke.reject(e.message ?: "Unknown error")
      }
    }
  }

  @Command
  fun stop(invoke: Invoke) {
    ensureReady {
      tts?.stop()
      invoke.resolve()
    }
  }

  /**
   * Open the system Text-to-Speech settings screen.
   * Equivalent to launching Settings.ACTION_TTS_SETTINGS.
   */
  @Command
  fun openTtsSettings(invoke: Invoke) {
    try {
      val intent = Intent(Settings.ACTION_TTS_SETTINGS)
      intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      activity.startActivity(intent)
      invoke.resolve()
    } catch (e: ActivityNotFoundException) {
      invoke.reject("Unable to open TTS settings")
    } catch (e: Exception) {
      invoke.reject("Failed to open TTS settings: ${e.message}")
    }
  }

  /**
   * Best-effort request to install TTS voice data from the active engine.
   * Returns true if an activity was launched; false otherwise.
   */
  @Command
  fun installTtsDataIfSupported(invoke: Invoke) {
    try {
      val intent = Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA)

      // Direct request to current engine package if known (improves success rate)
      currentEngine(tts)?.let { intent.`package` = it }

      intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      activity.startActivity(intent)
      invoke.resolve(true)
    } catch (_: ActivityNotFoundException) {
      invoke.resolve(false)
    } catch (_: Exception) {
      invoke.resolve(false)
    }
  }

  /**
   * Return a JSON array of offline-capable voices available from the current engine.
   * Each item matches the Rust `VoiceInfo` model:
   * { id, name, language, gender, quality, engine }
   *
   * - id: Voice.getName()
   * - name: null (Android doesn't expose a friendly display name)
   * - language: Locale#toLanguageTag()
   * - gender: "unspecified"
   * - quality: one of "very_low"|"low"|"normal"|"high"|"very_high"
   * - engine: current engine package
   */
  @Command
  fun listVoices(invoke: Invoke) {
    ensureReady {
      val t = tts
      if (t == null) {
        invoke.reject("TTS not initialized")
        return@ensureReady
      }

      val engine = currentEngine(t)
      val voices = t.voices ?: emptySet()

      val payload = mutableListOf<JSObject>()

      for (v in voices) {
        // Filter out network-only voices; Corpán is offline-first
        if (v.isNetworkConnectionRequired) continue

        val obj = JSObject()
        obj.put("id", v.name) // stable ID per engine
        obj.put("name", null) // Android doesn't expose a friendly label
        obj.put("language", v.locale?.toLanguageTag() ?: Locale.getDefault().toLanguageTag())
        obj.put("gender", "unspecified")
        obj.put("quality", when (v.quality) {
          Voice.QUALITY_VERY_HIGH -> "very_high"
          Voice.QUALITY_HIGH -> "high"
          Voice.QUALITY_NORMAL -> "normal"
          Voice.QUALITY_LOW -> "low"
          Voice.QUALITY_VERY_LOW -> "very_low"
          else -> "normal"
        })
        obj.put("engine", engine)
        payload.add(obj)
      }

      // Sort for nicer UX: language, quality desc, latency asc, id
      payload.sortWith(
        compareBy<JSObject> { it.getString("language") }
          .thenByDescending {
            when (it.getString("quality")) {
              "very_high" -> 5
              "high" -> 4
              "normal" -> 3
              "low" -> 2
              "very_low" -> 1
              else -> 3
            }
          }
          .thenBy { it.getString("id") }
      )

      // Return as a top-level JSON array (Vec<VoiceInfo> on the Rust side)
      invoke.resolve(payload)
    }
  }

  // Clean up
  override fun destroy() {
    try {
      tts?.stop()
      tts?.shutdown()
    } finally {
      tts = null
      isInitialized = false
      pendingActions.clear()
      super.destroy()
    }
  }
}
