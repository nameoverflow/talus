import AppKit
@main struct StatusRichTests {
 static func main() throws {
    let json = """
    {"spaceLabels":["term","web"],
     "statusTemplate":"%spaces% | <fc=#ABCDEF><fn=0>%layout%</fn></fc> | %safe% | %rich%",
     "workspaceCurrent":"<fc=#001122,#88CCBB> %label%%fullscreen% </fc>",
     "workspaceOther":"%index%:%label%",
     "statusFonts":["Menlo-Regular"],
     "statusCommands":[
       {"name":"safe","executable":"/bin/echo"},
       {"name":"rich","executable":"/bin/echo","markup":true}
     ]}
    """
    let config = try JSONDecoder().decode(Configuration.self,from:Data(json.utf8)); try config.validate()
    let spaces = [SpaceEntry(id:1,isCurrent:false,isFullscreen:false),SpaceEntry(id:2,isCurrent:true,isFullscreen:true)]
    let values = StatusValues(spaces:spaces,layout:"Tall",title:"Editor",count:2,custom:"CPU",paused:false,spaceLabels:config.spaceLabels)
    let parts = templateStatusParts(config:config,values:values) { index in
        index == 0 ? "<fc=red>literal</fc>" : "<fc=#FFAABB>styled</fc>"
    }
    precondition(parts.map(\.text).joined() == "1:term  web•  | Tall | <fc=red>literal</fc> | styled")
    let active = parts.first { $0.text == " web• " }!
    precondition(active.isCurrent && active.style?.foreground == "#001122" && active.style?.background == "#88CCBB")
    let layout = parts.first { $0.text == "Tall" }!
    precondition(layout.style?.foreground == "#ABCDEF" && layout.style?.font == "Menlo-Regular")
    precondition(parts.first { $0.text == "styled" }?.style?.foreground == "#FFAABB")
    precondition(parts.first { $0.text == "<fc=red>literal</fc>" }?.style?.foreground == nil)
    let image = configuredStatusImage(parts:parts,dark:true)
    precondition(!image.isTemplate && image.size.height == 18 && image.size.width > 20)
    let noIcon = configuredStatusImage(parts:parts,dark:true,showIcon:false)
    precondition(noIcon.size.width < image.size.width)
    var legacy = Configuration(); legacy.statusFormat = "{spaces} | {layout}"
    let oldParts = templateStatusParts(config:legacy,values:values)
    precondition(oldParts.map(\.text).joined() == "term  web•  | Tall")
    let inert = parseStatusMarkup("<action=run>text</action>",fonts:[],fontSize:11.5)
    precondition(inert.map(\.text).joined() == "<action=run>text</action>")
    let malformed = parseStatusMarkup("x<fc=bogus>y</fc>",fonts:[],fontSize:11.5)
    precondition(malformed.map(\.text).joined() == "x<fc=bogus>y</fc>")
    let literal = parseStatusMarkup("100%%",fonts:[],fontSize:11.5)
    precondition(literal.map(\.text).joined() == "100%")

    // Virtual workspace entries: occupied non-current stays full contrast; empty non-current dims
    var vConfig = Configuration()
    vConfig.workspaceMode = "virtual"
    vConfig.workspaceOther = " %label%%occupied% "
    let vSpaces = [
        SpaceEntry(id:1, isCurrent:true, isFullscreen:false, windowCount:2),
        SpaceEntry(id:2, isCurrent:false, isFullscreen:false, windowCount:1),
        SpaceEntry(id:3, isCurrent:false, isFullscreen:false, windowCount:0),
    ]
    let vValues = StatusValues(spaces:vSpaces, layout:"Tall", title:"", count:2, custom:"", paused:false)
    let vParts = templateStatusParts(config:vConfig, values:vValues)
    precondition(vParts.first { $0.text.contains("2•") }?.style?.dimmed == false)
    precondition(vParts.first { $0.text.contains("3") }?.style?.dimmed == true)

    // Clickable workspace hit regions are recorded in order and non-overlapping
    let rendered = renderConfiguredStatus(parts:vParts, dark:true, showIcon:true, hoveredWorkspace:1)
    precondition(rendered.workspaceRegions.count == 3)
    precondition(rendered.workspaceRegions.map(\.index) == [0, 1, 2])
    precondition(rendered.workspaceRegions[0].rect.maxX < rendered.workspaceRegions[1].rect.minX)
    precondition(rendered.workspaceRegions[1].rect.maxX < rendered.workspaceRegions[2].rect.minX)

    // <box> underline/outline tags & empty-foreground background <fc=,#bg>
    let boxParts = parseStatusMarkup("<box type=Bottom width=2 color=#14B8A6>ws1</box> <fc=,#80808024>ws2</fc> <box type=bogus>raw</box>", fonts:[], fontSize:11.5)
    precondition(boxParts.first { $0.text == "ws1" }?.style?.box == StatusBoxStyle(type: .bottom, width: 2, color: "#14B8A6", radius: nil))
    let bgOnly = boxParts.first { $0.text == "ws2" }!
    precondition(bgOnly.style?.foreground == nil && bgOnly.style?.background == "#80808024")
    precondition(boxParts.map(\.text).joined().contains("<box type=bogus>raw</box>"))
    let boxImg = configuredStatusImage(parts: boxParts, dark: true)
    precondition(boxImg.size.height == 18 && boxImg.size.width > 30)

    // <sf=...> SF Symbol tags and %icon% workspace icon resolution
    var iconCfg = Configuration()
    iconCfg.workspaceMode = "virtual"
    iconCfg.workspaceIcons = ["terminal", "globe", "chevron.left.forwardslash.chevron.right"]
    iconCfg.workspaceCurrent = "<fc=#FFFFFF,#0F766E> %icon% </fc>"
    iconCfg.workspaceOther = " %icon% "
    let iconValues = StatusValues(spaces: vSpaces, layout: "Tall", title: "", count: 2, custom: "", paused: false, spaceLabels: ["终端", "网页", "代码"], spaceIcons: iconCfg.workspaceIcons)
    let iconParts = templateStatusParts(config: iconCfg, values: iconValues)
    precondition(iconParts.compactMap(\.symbolName) == ["terminal", "globe", "chevron.left.forwardslash.chevron.right"])
    let iconImg = configuredStatusImage(parts: iconParts, dark: true)
    precondition(iconImg.size.height == 18 && iconImg.size.width > 60)

    let inlineSf = parseStatusMarkup("<sf=terminal> <sf=bogus!!>", fonts: [], fontSize: 11.5)
    precondition(inlineSf.first?.symbolName == "terminal")
    precondition(inlineSf.map(\.text).joined().contains("<sf=bogus!!>"))

    // Switching active workspace between icon workspaces keeps identical total width and slot widths
    var fullIconCfg = Configuration()
    fullIconCfg.workspaceMode = "virtual"
    fullIconCfg.workspaceIcons = ["terminal", "globe", "chevron.left.forwardslash.chevron.right", "bubble.left.and.bubble.right", "square.grid.2x2"]
    fullIconCfg.statusTemplate = "%spaces%  %layout% · %count%"
    fullIconCfg.workspaceCurrent = "<fc=#FFFFFF,#0F766E> %icon%%fullscreen% </fc>"
    fullIconCfg.workspaceOther = " %icon%%fullscreen% "
    func renderWithActive(_ activeIdx: Int) -> StatusRenderOutput {
        let spaces = (0..<5).map { SpaceEntry(id: UInt64($0 + 1), isCurrent: $0 == activeIdx, isFullscreen: false, windowCount: 1) }
        let vals = StatusValues(spaces: spaces, layout: "Tall", title: "", count: 1, custom: "", paused: false, spaceLabels: ["1","2","3","4","5"], spaceIcons: fullIconCfg.workspaceIcons)
        return renderConfiguredStatus(parts: templateStatusParts(config: fullIconCfg, values: vals), dark: true)
    }
    let out0 = renderWithActive(0)
    let out2 = renderWithActive(2)
    precondition(out0.image.size.width == out2.image.size.width)
    precondition(out0.workspaceRegions == out2.workspaceRegions)
    precondition(Set(out0.workspaceRegions.map { $0.rect.width }).count == 1)

    print("Status templates, colours, fonts and command markup tests passed")
 }
}
