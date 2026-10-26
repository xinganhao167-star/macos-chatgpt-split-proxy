// PAC 文件：只有 OpenAI / ChatGPT 相关域名走本地代理，其余全部直连。
//
// 由 install.sh 自动生成并托管在 http://127.0.0.1:8899/split.pac
// 重要：必须用 http:// 提供，不能用 file://——Safari / WebKit 会直接忽略 file:// 的 PAC。
// 域名清单来自 OpenAI 官方网络建议（Network Recommendations for ChatGPT errors）：
// https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps

function FindProxyForURL(url, host) {
    host = host.toLowerCase();

    // ChatGPT 网页版 / 桌面端 / API 及其登录、支付、统计等依赖域名
    var openaiDomains = [
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

    // 其余一律直连：国内站点不绕路、不改出口 IP
    return "DIRECT";
}
