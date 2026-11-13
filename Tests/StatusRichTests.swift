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
    print("Status templates, colours, fonts and command markup tests passed")
 }
}
