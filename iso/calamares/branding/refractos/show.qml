/* Refract OS Calamares install slideshow.
 *
 * Real QML syntax, verified against Calamares' own default slideshow
 * source (calamares/calamares src/branding/default/show.qml) and its
 * src/branding/README.md -- not fabricated. Uses slideshowAPI 2 (async
 * load, onActivate()/onLeave() lifecycle functions) since branding.desc
 * sets slideshowAPI: 2 and Calamares' own docs flag API 1 (onCompleted-based)
 * as on a path to deprecation. The Timer bound to
 * presentation.activatedInCalamares is documented to work under both API
 * versions, so slide auto-advance doesn't depend on the (deprecated) API 1
 * onCompleted signal at all.
 */
import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    function nextSlide() {
        presentation.goToNextSlide();
    }

    Timer {
        id: advanceTimer
        interval: 6000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: nextSlide()
    }

    Slide {
        // No logo image: the OS ships no Refract mark, and logo.png here is a
        // 1x1 transparent stand-in. Keeping the 160px Image reserved an empty
        // ~200px band above the title because both Texts anchored to its bottom.
        Text {
            anchors.top: parent.top
            anchors.topMargin: 90
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("Refract OS")
            font.pixelSize: 32
            font.bold: true
            color: "#ffffff"
        }
        Text {
            anchors.top: parent.top
            anchors.topMargin: 136
            anchors.horizontalCenter: parent.horizontalCenter
            width: presentation.width * 0.7
            horizontalAlignment: Text.Center
            wrapMode: Text.WordWrap
            // Mode-agnostic ON PURPOSE — build.sh strips the per-mode slides below
            // for an omitted mode but CANNOT strip this one, so anything it claims
            // must hold for every build. The old text ended "-- plus broad,
            // practical Windows app and game compatibility", which is a Gaming-mode
            // claim on the one slide Gaming's absence cannot remove: a -nogaming
            // image promised Windows game support it provably did not have. It was
            // not even true of a full build, since no strain bakes Wine in at all
            // (libwine is ~647 MB; modes/gaming/setup/03-install-wine-staging.sh
            // installs it on demand). The gaming slide below already makes the
            // claim, correctly scoped and correctly stripped. Same sentence as the
            // welcome banner and the MOTD, so all three surfaces agree.
            text: qsTr("One install, switchable modes for whatever this machine is for.")
            color: "#cccccc"
        }
    }

    // @slide:gaming
    Slide {
        centeredText: qsTr("Gaming mode: one command installs and tunes Proton-GE, Wine-staging and Bottles (GameMode and MangoHud ship in the image) -- broad practical compatibility, not an unrealistic promise of 100%.")
    }
    // @endslide:gaming

    // @slide:ai
    Slide {
        centeredText: qsTr("AI mode: a local-first AI layer built on Ollama (chat + coding models on your own GPU, OpenAI-compatible server) and ComfyUI for image generation -- sized to your hardware, no API keys, no cloud, no telemetry by default.")
    }
    // @endslide:ai

    // @slide:server
    Slide {
        centeredText: qsTr("Server mode: SSH hardening, Docker, and Netdata monitoring -- fully usable with no display attached at all.")
    }
    // @endslide:server

    // @slide:creative
    Slide {
        centeredText: qsTr("Creative mode: FreeCAD, Blender, Kdenlive, DaVinci Resolve, and ffmpeg (NVENC) -- native Linux apps with real GPU acceleration, not a fragile Wine workaround.")
    }
    // @endslide:creative

    Slide {
        centeredText: qsTr("Normal mode: a polished, macOS-style desktop -- dock, top bar, and a clean default theme for everyday use.")
    }

    function onActivate() {
        presentation.currentSlide = 0;
    }

    function onLeave() {
    }
}
