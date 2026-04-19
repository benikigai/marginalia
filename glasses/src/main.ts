import {
  waitForEvenAppBridge,
  type EvenAppBridge,
  CreateStartUpPageContainer,
  TextContainerProperty,
  TextContainerUpgrade,
  RebuildPageContainer,
  OsEventTypeList,
  EventSourceType,
} from '@evenrealities/even_hub_sdk'
import type { EvenHubEvent } from '@evenrealities/even_hub_sdk'

// ─── Configuration ──────────────────────────────────────────
// Read server URL from query param: ?server=172.20.10.2:8080
// Falls back to hardcoded default for development
function getServerUrl(): string {
  if (typeof window !== 'undefined') {
    const params = new URLSearchParams(window.location.search)
    const server = params.get('server')
    if (server) return `http://${server}`
  }
  return 'http://172.20.10.2:8080'
}
const SERVER_URL = getServerUrl()
const AUDIO_BUFFER_MS = 3000

// Glyphs — Ben confirmed in G2 firmware. Fallback: ● / ○ if ◉ doesn't render
const GLYPH_SELECTED = '◉'
const GLYPH_UNSELECTED = '○'
const GLYPH_DONE = '✓'

// ─── Types ──────────────────────────────────────────────────
type AppState = 'LISTENING' | 'PROCESSING' | 'OPTIONS' | 'EXECUTING' | 'DONE'

interface Option {
  label: string
  action: string | null
  args: Record<string, any> | null
}

// ─── State ──────────────────────────────────────────────────
let bridge: EvenAppBridge
let state: AppState = 'LISTENING'
let options: Option[] = []
let selectedIndex = 0
let audioChunks: Uint8Array[] = []
let audioBufferStartTime = 0
let scrollCooldown = 0

const CONTAINER_ID = 1
const CONTAINER_NAME = 'main'

// ─── Logging ────────────────────────────────────────────────
function log(msg: string) {
  console.log(`[Marginalia] ${msg}`)
  // Also show in browser debug view (visible before bridge connects)
  const el = document.getElementById('log')
  if (el) {
    el.textContent = `${msg}\n${el.textContent}`.slice(0, 2000)
  }
}

// ─── Display helpers ────────────────────────────────────────
async function showStartupPage(): Promise<void> {
  const result = await bridge.createStartUpPageContainer(
    new CreateStartUpPageContainer({
      containerTotalNum: 1,
      textObject: [
        new TextContainerProperty({
          containerID: CONTAINER_ID,
          containerName: CONTAINER_NAME,
          content: 'MARGINALIA\n\nListening...',
          xPosition: 20,
          yPosition: 20,
          width: 536,
          height: 248,
          borderWidth: 1,
          borderColor: 8,
          borderRadius: 5,
          paddingLength: 12,
          isEventCapture: 1,
        }),
      ],
    })
  )
  log(`Startup page created: result=${result}`)
}

async function updateDisplay(content: string): Promise<void> {
  await bridge.textContainerUpgrade(
    new TextContainerUpgrade({
      containerID: CONTAINER_ID,
      containerName: CONTAINER_NAME,
      content,
    })
  )
}

function buildOptionsDisplay(): string {
  return options
    .map((opt, i) => {
      const glyph = i === selectedIndex ? GLYPH_SELECTED : GLYPH_UNSELECTED
      return `${glyph} ${opt.label}`
    })
    .join('\n')
}

// ─── Audio handling ─────────────────────────────────────────
function startAudioCapture(): void {
  bridge.audioControl(true).then((ok) => {
    log(`Audio control: ${ok ? 'started' : 'FAILED'}`)
  })
}

function onAudioFrame(pcm: Uint8Array): void {
  if (state !== 'LISTENING') return

  const now = Date.now()
  if (audioChunks.length === 0) {
    audioBufferStartTime = now
  }

  audioChunks.push(new Uint8Array(pcm)) // copy the frame

  if (now - audioBufferStartTime >= AUDIO_BUFFER_MS) {
    const buffer = concatChunks(audioChunks)
    audioChunks = []
    log(`Audio buffer complete: ${buffer.length} bytes`)
    sendAudioForInference(buffer)
  }
}

function concatChunks(chunks: Uint8Array[]): Uint8Array {
  const totalLength = chunks.reduce((sum, c) => sum + c.length, 0)
  const result = new Uint8Array(totalLength)
  let offset = 0
  for (const chunk of chunks) {
    result.set(chunk, offset)
    offset += chunk.length
  }
  return result
}

// ─── Server communication ───────────────────────────────────
async function sendAudioForInference(pcmBuffer: Uint8Array): Promise<void> {
  state = 'PROCESSING'
  await updateDisplay('MARGINALIA\n\nProcessing...')

  try {
    // Send as base64 JSON payload
    const base64 = uint8ArrayToBase64(pcmBuffer)
    const response = await fetch(`${SERVER_URL}/inference-json`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        audio: base64,
        sampleRate: 16000,
        channels: 1,
        bitsPerSample: 16,
      }),
    })

    if (!response.ok) {
      throw new Error(`Server returned ${response.status}`)
    }

    const data = await response.json()
    log(`Inference response: ${JSON.stringify(data)}`)

    if (data.options && Array.isArray(data.options) && data.options.length === 3) {
      options = data.options
      selectedIndex = 0
      state = 'OPTIONS'
      await updateDisplay(buildOptionsDisplay())
      log('Options displayed on lens')
    } else {
      log(`Invalid response shape: ${JSON.stringify(data)}`)
      resetToListening()
    }
  } catch (err) {
    log(`Inference error: ${err}`)
    resetToListening()
  }
}

async function executeToolCall(option: Option): Promise<void> {
  if (!option.action) {
    // No action to execute, just acknowledge
    state = 'DONE'
    await updateDisplay(`${GLYPH_DONE} Done — ${option.label}`)
    log(`Selected (no action): ${option.label}`)
    setTimeout(() => resetToListening(), 2000)
    return
  }

  state = 'EXECUTING'
  await updateDisplay(`Executing...\n${option.label}`)

  try {
    const response = await fetch(`${SERVER_URL}/tool-call-json`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        tool: option.action,
        args: option.args,
      }),
    })

    if (!response.ok) {
      throw new Error(`Tool call returned ${response.status}`)
    }

    const data = await response.json()
    log(`Tool call result: ${JSON.stringify(data)}`)

    state = 'DONE'
    await updateDisplay(`${GLYPH_DONE} Done — ${option.label}`)
    setTimeout(() => resetToListening(), 2000)
  } catch (err) {
    log(`Tool call error: ${err}`)
    state = 'DONE'
    await updateDisplay(`Error — ${option.label}`)
    setTimeout(() => resetToListening(), 2000)
  }
}

async function resetToListening(): Promise<void> {
  state = 'LISTENING'
  options = []
  selectedIndex = 0
  audioChunks = []
  await updateDisplay('MARGINALIA\n\nListening...')
  log('Reset to listening')
}

// ─── Event handling ─────────────────────────────────────────
function resolveEventType(event: EvenHubEvent): OsEventTypeList | undefined {
  if (event.textEvent) return event.textEvent.eventType
  if (event.sysEvent) return event.sysEvent.eventType
  if (event.listEvent) return event.listEvent.eventType
  return undefined
}

function onEvent(event: EvenHubEvent): void {
  // Handle audio events
  if (event.audioEvent) {
    onAudioFrame(event.audioEvent.audioPcm)
    return
  }

  const eventType = resolveEventType(event)
  const source = event.sysEvent?.eventSource

  log(`Event: type=${eventType} source=${source} state=${state}`)

  switch (state) {
    case 'LISTENING':
      // Double-tap exits the app (Even Hub requirement)
      if (eventType === OsEventTypeList.DOUBLE_CLICK_EVENT) {
        bridge.shutDownPageContainer(1)
        return
      }
      break

    case 'OPTIONS':
      handleOptionsEvent(eventType)
      break

    case 'PROCESSING':
    case 'EXECUTING':
      // Ignore input during processing
      break

    case 'DONE':
      // Ignore input during done state
      break
  }
}

function handleOptionsEvent(eventType: OsEventTypeList | undefined): void {
  const now = Date.now()

  // Click or tap — select current option
  if (eventType === OsEventTypeList.CLICK_EVENT || eventType === undefined) {
    log(`Selected option ${selectedIndex}: ${options[selectedIndex]?.label}`)
    executeToolCall(options[selectedIndex])
    return
  }

  // Double-tap — cancel back to listening
  if (eventType === OsEventTypeList.DOUBLE_CLICK_EVENT) {
    log('Options cancelled via double-tap')
    resetToListening()
    return
  }

  // Scroll/ring rotation — move selection (with cooldown)
  if (now - scrollCooldown < 300) return
  scrollCooldown = now

  if (eventType === OsEventTypeList.SCROLL_BOTTOM_EVENT) {
    selectedIndex = (selectedIndex + 1) % options.length
    updateDisplay(buildOptionsDisplay())
    log(`Selection moved to ${selectedIndex}`)
    return
  }

  if (eventType === OsEventTypeList.SCROLL_TOP_EVENT) {
    selectedIndex = (selectedIndex - 1 + options.length) % options.length
    updateDisplay(buildOptionsDisplay())
    log(`Selection moved to ${selectedIndex}`)
    return
  }
}

// ─── Utilities ──────────────────────────────────────────────
function uint8ArrayToBase64(bytes: Uint8Array): string {
  let binary = ''
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i])
  }
  return btoa(binary)
}

// ─── Bootstrap ──────────────────────────────────────────────
async function main(): Promise<void> {
  log('Marginalia starting...')
  log(`Server URL: ${SERVER_URL}`)

  try {
    bridge = await waitForEvenAppBridge()
    log('Bridge connected')

    // Register event listener
    bridge.onEvenHubEvent((event: EvenHubEvent) => {
      onEvent(event)
    })

    // Show initial page
    await showStartupPage()
    log('Startup page displayed')

    // Start audio capture
    startAudioCapture()

    log('Marginalia ready — listening for audio')
  } catch (err) {
    log(`Fatal: ${err}`)
  }
}

main()
