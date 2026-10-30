import Foundation

let node = ProxyNode.fallback
precondition(node.server == "proxy.example.com")
precondition(node.password == "CHANGE_ME")
precondition(node.insecure == false)
let rendered = ConfigWriter.render(node: node, settings: .defaults)
precondition(rendered.contains("server: proxy.example.com:443"))
precondition(rendered.contains("insecure: false"))
precondition(rendered.contains("listen: 127.0.0.1:10800"))
precondition(rendered.contains("listen: 127.0.0.1:10801"))
print("Example node and config rendering checks passed")
