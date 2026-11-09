// PAC 文件：只有 OpenAI / ChatGPT、X、GitHub、Google 相关域名走本地代理，其余全部直连。
//
// 由 install.sh 自动生成并托管在 http://127.0.0.1:8899/split.pac
// 重要：必须用 http:// 提供，不能用 file://——Safari / WebKit 会直接忽略 file:// 的 PAC。
// 域名清单来自 OpenAI 官方网络建议（Network Recommendations for ChatGPT errors）：
// https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps

function FindProxyForURL(url, host) {
    host = host.toLowerCase();

    // ChatGPT 网页版 / 桌面端 / API 及其登录、支付、统计等依赖域名
    var openaiDomains = [
        "openai.com",
        "chatgpt.com",
        "*.openai.com",
        "*.chatgpt.com",
        "*.oaistatic.com",
        "*.oaistatsig.com",
        "*.oaiusercontent.com",
        "*.openaimerge.com",
        "*.ct.sendgrid.net",
        "*.intercom.io",
        "*.intercomcdn.com",
        "*.js.intercomcdn.com",
        "*.workos.com",
        "*.workoscdn.com",
        "*.imgix.net",
        "*.stripe.com",
        "*.js.stripe.com",
        "*.sentry.io",
        "*.ingest.sentry.io",
        "*.datadoghq.com",
        "challenges.cloudflare.com",
        "auth0.openai.com",
        "cdn.openai.com",
        "cdn.oaistatic.com",
        "cdn.openaimerge.com",
        "cdn.platform.openai.com",
        "chat.openai.com",
        "desktop.chat.openai.com",
        "setup.auth.openai.com",
        "setup.workos.com",
        "forwarder.workos.com",
        "frontend-apps-multi-region.workos.com",
        "images.workoscdn.com",
        "tcr9i.chat.openai.com"
    ];

    for (var i = 0; i < openaiDomains.length; i++) {
        if (shExpMatch(host, openaiDomains[i])) {
            return "PROXY 127.0.0.1:8080";
        }
    }

    // X 网页、旧版 Twitter 域名、链接跳转和图片/视频资源
    var xDomains = [
        "x.com",
        "*.x.com",
        "twitter.com",
        "*.twitter.com",
        "t.co",
        "twimg.com",
        "*.twimg.com"
    ];

    for (var j = 0; j < xDomains.length; j++) {
        if (shExpMatch(host, xDomains[j])) {
            return "PROXY 127.0.0.1:8080";
        }
    }

    // GitHub：主站、API、Gist、代码下载与静态资源
    var githubDomains = [
        "github.com",
        "*.github.com",
        "githubusercontent.com",
        "*.githubusercontent.com",
        "githubassets.com",
        "*.githubassets.com"
    ];

    for (var k = 0; k < githubDomains.length; k++) {
        if (shExpMatch(host, githubDomains[k])) {
            return "PROXY 127.0.0.1:8080";
        }
    }

    // Google：搜索与账号、Drive/Docs/Gmail 等 Workspace、YouTube、Firebase/Cloud、
    // 静态资源与下载、头像图片、reCAPTCHA 等
    // 不含 google.cn / googleapis.cn / gstatic.cn：这三个是国内可直连的镜像，留在直连侧更快。
    var googleDomains = [
        "google.com",
        "*.google.com",
        "googleapis.com",
        "*.googleapis.com",
        "gstatic.com",
        "*.gstatic.com",
        "googleusercontent.com",
        "*.googleusercontent.com",
        "ggpht.com",
        "*.ggpht.com",
        "gmail.com",
        "*.gmail.com",
        "googlemail.com",
        "*.googlemail.com",
        "youtube.com",
        "*.youtube.com",
        "youtu.be",
        "youtube-nocookie.com",
        "*.youtube-nocookie.com",
        "ytimg.com",
        "*.ytimg.com",
        "googlevideo.com",
        "*.googlevideo.com",
        "blogger.com",
        "*.blogger.com",
        "blogspot.com",
        "*.blogspot.com",
        "firebaseio.com",
        "*.firebaseio.com",
        "firebaseapp.com",
        "*.firebaseapp.com",
        "crashlytics.com",
        "*.crashlytics.com",
        "appspot.com",
        "*.appspot.com",
        "cloudfunctions.net",
        "*.cloudfunctions.net",
        "run.app",
        "*.run.app",
        "gcr.io",
        "*.gcr.io",
        "pkg.dev",
        "*.pkg.dev",
        "googlesource.com",
        "*.googlesource.com",
        "gvt1.com",
        "*.gvt1.com",
        "gvt2.com",
        "*.gvt2.com",
        "recaptcha.net",
        "*.recaptcha.net",
        "ampproject.org",
        "*.ampproject.org"
    ];

    for (var m = 0; m < googleDomains.length; m++) {
        if (shExpMatch(host, googleDomains[m])) {
            return "PROXY 127.0.0.1:8080";
        }
    }

    // 其余一律直连：其他站点不绕路、不改出口 IP
    return "DIRECT";
}
