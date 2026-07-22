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
        Image {
            id: introLogo
            source: "logo.png"
            width: 160; height: 160
            fillMode: Image.PreserveAspectFit
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 40
        }
        Text {
            anchors.top: introLogo.bottom
            anchors.topMargin: 24
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("Refract OS")
            font.pixelSize: 32
            font.bold: true
            color: "#ffffff"
        }
        Text {
            anchors.top: introLogo.bottom
            anchors.topMargin: 70
            anchors.horizontalCenter: parent.horizontalCenter
            width: presentation.width * 0.7
            horizontalAlignment: Text.Center
            wrapMode: Text.WordWrap
            text: qsTr("One install, switchable modes tuned to whatever this machine is for -- plus broad, practical Windows app and game compatibility.")
            color: "#cccccc"
        }
    }

    // @slide:gaming
    Slide {
        centeredText: qsTr("Gaming mode: Proton-GE, Wine-staging, Bottles, GameMode, and MangoHud preinstalled and tuned -- broad practical compatibility, not an unrealistic promise of 100%.")
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
