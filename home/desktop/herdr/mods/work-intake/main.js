import { View, div } from "gpui-kit";
import { h_flex, v_flex, TextView } from "gpui-base";
import { props, theme, readTextFile, shared, setShared, run, closeOverlay, notify, exec } from "herdr";
import { expired, shouldNotify, localSourcePath, visibleItems, historyPage } from "./model.js";

const ROOT = "@notesRoot@";
const READ = "work-intake.read-run", NOTIFIED = "work-intake.notified-run", REMINDED = "work-intake.reminded-items";

export default class Intake extends View {
  init(_props,cx) {
    this.data=null; this.error=null; this.message=""; this.loading=false; this.busy=false; this.refreshQueued=false;
    this.raw=""; this.selected=""; this.section="now"; this.filter="open"; this.historyOffset=0;
    this.source=null; this.linking=null; this.importedRead=false;
    this.refresh(cx);
    cx.timer.every(15000,cx=>this.refresh(cx));
  }
  async call(args) {
    const result=await exec("herdr-intake-dashboard",args);
    if(result.code!==0) throw new Error(result.stderr.trim()||"Intake could not load the requested data.");
    return JSON.parse(result.stdout);
  }
  refresh(cx) {
    if(this.loading){this.refreshQueued=true;return;}
    this.loading=true;
    const selected=this.selected;
    cx.spawn(async cx=>{
      try {
        const args=["view",...(selected?["--report",selected]:[])];
        let value=await this.call(args);
        const legacy=shared(READ);
        if(!this.importedRead && legacy && value.history.some(r=>r.run_id===legacy) && !value.read_report_ids.includes(legacy)) {
          await this.call(["action","--request",JSON.stringify({action:"read",report_id:legacy,operation_id:"import-read-"+legacy})]);
          value=await this.call(args);
        }
        this.importedRead=true;
        if(selected!==this.selected)return;
        const raw=JSON.stringify(value),changed=raw!==this.raw||Boolean(this.error);
        this.raw=raw;this.data=value;this.error=null;
        if(!props()?.overlay && value.report) {
          if(shouldNotify(value.report,shared(NOTIFIED))) {
            notify({title:value.report.attention==="urgent"?"Intake: needs attention":"Your next 2 hours",body:value.report.summary,
              level:value.report.attention==="urgent"?"warning":"info",timeout:14000,action:{name:"mod.open",args:{name:"work-intake"}}});
            setShared(NOTIFIED,value.report.run_id);
          }
          const reminded=shared(REMINDED)||{},due=value.reminders.filter(i=>!reminded[i.reminder_key]);
          if(due.length) {
            notify({title:"Intake reminder",body:due.map(i=>i.title).join(" · ").slice(0,300),level:"info",timeout:14000,action:{name:"mod.open",args:{name:"work-intake"}}});
            for(const item of due)reminded[item.reminder_key]=true;
            setShared(REMINDED,reminded);
          }
        }
        if(changed)cx.notify();
      } catch(error){if(selected===this.selected){this.error=String(error);cx.notify();}}
      finally{
        this.loading=false;
        if(this.refreshQueued){this.refreshQueued=false;this.refresh(cx);}
      }
    });
  }
  button(id,label,action,active=false) {
    const t=theme();
    return div().id(id).px(10).py(7).rounded(5).text_size(12).text_color(active?t.accent:t.foreground)
      .bg(active?t.hover:t.raised).hover(s=>s.bg(t.hover)).on_click((event,cx)=>{if(!this.busy)action(event,cx);}).child(label);
  }
  chooseReport(id,cx) {
    this.selected=id===this.data.latest?"":id;this.data=null;this.source=null;this.linking=null;this.message="";this.section="now";
    this.refresh(cx);cx.notify();
  }
  act(action,item,cx,extra={}) {
    const request={action,report_id:item?.report_id||this.data.report.run_id,operation_id:"ui-"+Date.now()+"-"+Math.random().toString(36).slice(2),...extra};
    if(item){request.item_id=item.id;if(item.todo_link)request.todo_etag=item.todo_link.etag;}
    this.submit(request,cx);
  }
  submit(request,cx) {
    if(this.busy)return;
    this.busy=true;this.message="Saving…";cx.notify();
    cx.spawn(async cx=>{
      try {
        const result=await this.call(["action","--request",JSON.stringify(request)]);
        this.message=result.message;this.linking=null;
        if(request.action==="read")setShared(READ,request.report_id);
      } catch(error){this.message=String(error);}
      finally{this.busy=false;this.refresh(cx);cx.notify();}
    });
  }
  openSource(url,cx,origin) {
    if(/^https?:\/\//.test(url)){cx.spawn(async()=>{await exec("xdg-open",[url]);});return;}
    const relative=localSourcePath(url,origin||this.source?.path||this.data.report.briefing_path);
    if(!relative){this.message="This source link cannot be opened inside the vault.";cx.notify();return;}
    cx.spawn(async cx=>{
      try {
        const text=await readTextFile(ROOT+relative);
        if(text===null)throw new Error("The linked source file is unavailable.");
        this.source={path:relative,text:relative.endsWith(".json")?"```json\n"+text+"\n```":text};
      }catch(error){this.message=String(error);}cx.notify();
    });
  }
  findTodo(item,cx) {
    const selected=this.selected;
    cx.spawn(async cx=>{
      try{
        const candidates=await this.call(["candidates","--title",item.title]);
        if(selected===this.selected)this.linking={item,candidates};
      }
      catch(error){this.message=String(error);}cx.notify();
    });
  }
  markdown(id,text){return TextView.markdown(id,text).selectable(true).on_link_click((url,cx)=>this.openSource(url,cx));}
  item(item,prefix="item-") {
    const t=theme(),f=item.followup||{},status=item.effective_status||"open",id=prefix+item.id;
    const pending=this.data.pending.some(p=>p.request.item_id===item.id);
    const body=v_flex().id(id).gap(9).py(15).border_b(1).border_color(t.border)
      .child(h_flex().gap(12).items_center().child(div().text_size(12).text_color(t.accent).child(item.kind==="decision"?"Decision":item.kind==="waiting"?"Waiting":"Action"))
        .child(div().text_size(12).text_color(t.muted).child(status==="snoozed"?"Reminder: "+(f.display_reminder||f.remind_at):status)))
      .child(div().text_size(16).font_semibold().text_color(t.foreground).child(item.title))
      .child(div().text_size(12).text_color(t.muted).child([item.owner,item.effort].filter(Boolean).join(" · ")))
      .when(Boolean(item.timing),el=>el.child(div().text_size(13).child(item.timing)))
      .when(Boolean(item.todo_link),el=>el.child(div().text_size(12).text_color(t.accent).child("Linked vault action: "+item.todo_link.ref.title)))
      .when(Boolean(item.todo_error),el=>el.child(div().text_size(12).text_color(t.blocked).child(item.todo_error)))
      .child(h_flex().gap(7).children((item.sources||[]).map((s,i)=>this.button(id+"-source-"+i,s.label,(_e,cx)=>this.openSource(s.url,cx,s.origin||this.data.report.briefing_path)))));
    if(status!=="done")body.child(h_flex().gap(6)
      .when(!item.todo_error&&!pending,el=>el.child(this.button(id+"-done",item.todo_link?"Complete vault action":"Done in Intake",(_e,cx)=>this.act("done",item,cx))))
      .children([
      this.button(id+"-hour","Remind in 1h",(_e,cx)=>this.act("remind-hour",item,cx)),
      this.button(id+"-tomorrow","Tomorrow 09:00",(_e,cx)=>this.act("remind-tomorrow",item,cx)),
      this.button(id+"-waiting","Waiting on others",(_e,cx)=>this.act("waiting",item,cx))])
      .when(!pending,el=>el.child(this.button(id+"-link",item.todo_link||item.todo_error?"Change TODO link":"Link vault action",(_e,cx)=>this.findTodo(item,cx)))));
    else if(!item.todo_link||item.todo_link.status!=="done")body.child(this.button(id+"-reopen","Reopen Intake item",(_e,cx)=>this.act("open",item,cx)));
    return body;
  }
  content() {
    const t=theme(),d=this.data;
    if(this.source)return this.markdown("intake-source",this.source.text);
    if(this.linking)return v_flex().gap(12).child(div().text_size(17).font_semibold().child("Choose the exact vault action"))
      .child(div().text_size(13).text_color(t.muted).child("Suggestions only. Review the scope before linking; linking does not complete an action."))
      .children(this.linking.candidates.map((c,i)=>v_flex().gap(8).py(12).border_b(1).border_color(t.border)
        .child(div().text_size(14).font_semibold().child(c.ref.title)).child(div().text_size(12).text_color(t.muted).child(c.ref.owner+" · Opened "+c.ref.opened))
        .child(div().text_size(13).child(c.preview)).child(this.button("link-candidate-"+i,"Link this action",(_e,cx)=>this.act("link",this.linking.item,cx,{todo:c.ref})))))
      .when(!this.linking.candidates.length,el=>el.child(div().child("No matching open TODO found. Keep the follow-up in Intake or open TODO.md.")));
    if(this.section==="report")return this.markdown("intake-full-report",d.report.briefing_markdown);
    if(this.section==="history") {
      const page=historyPage(d.history,this.historyOffset,8);
      return v_flex().gap(12).child(div().text_size(13).text_color(t.muted).child(d.history.length+" saved reports. Report text stays unchanged; follow-up state is current."))
        .children(page.items.map(r=>v_flex().gap(6).py(12).border_b(1).border_color(t.border)
          .child(this.button("report-"+r.run_id,r.date_label,(_e,cx)=>this.chooseReport(r.run_id,cx),r.run_id===d.report.run_id))
          .child(div().text_size(13).child(r.summary)).child(div().text_size(12).text_color(t.muted).child((r.read?"Read":"Unread")+" · "+r.coverage+" coverage"+(r.saved_only?" · Saved before desktop delivery":"")))))
        .child(h_flex().gap(8).when(page.hasNewer,el=>el.child(this.button("history-newer","Newer reports",(_e,cx)=>{this.historyOffset=Math.max(0,this.historyOffset-8);cx.notify();})))
          .when(page.hasOlder,el=>el.child(this.button("history-older","Older reports",(_e,cx)=>{this.historyOffset+=8;cx.notify();}))));
    }
    if(this.section==="sources")return v_flex().gap(12)
      .child(div().text_size(13).text_color(t.muted).child("Coverage recorded for this report. An unavailable source does not mean there was no new activity."))
      .children(d.report.sources.map(s=>v_flex().gap(7).py(14).border_b(1).border_color(t.border)
        .child(div().text_size(16).font_semibold().child(s.source.replaceAll("_"," ")))
        .child(div().text_size(13).text_color(s.status==="unavailable"?t.blocked:t.accent).child(s.status+" · Checked through: "+s.display_checked))
        .children(s.gaps.map(g=>div().text_size(13).text_color(t.muted).child(g)))))
      .when(!d.report.sources.length,el=>el.child(div().child("No structured coverage record. Open the full report for its qualifications.")));
    if(this.section==="changes") {
      const c=d.changes;
      return v_flex().gap(14).child(div().text_size(15).font_semibold().child("Since "+d.baseline_label))
        .child(div().text_size(13).text_color(t.muted).child(c.new.length+" new · "+c.changed.length+" changed · "+c.unchanged+" unchanged"))
        .children(c.new.map(i=>v_flex().gap(5).py(10).child(div().text_color(t.accent).child("New action")).child(div().child(i.title))))
        .children(c.changed.map(c=>v_flex().gap(7).py(10).child(div().text_color(t.accent).child("Changed")).child(div().font_semibold().child(c.item.title))
          .child(div().text_size(12).text_color(t.muted).child("Previously: "+c.before.title+" · "+c.before.timing)).child(div().text_size(13).child(c.item.timing))))
        .when(c.coverage_changed,el=>el.child(div().text_size(13).text_color(t.accent).child("Source coverage changed. See Sources for the recorded gaps.")))
        .when(c.not_listed.length>0,el=>el.child(div().text_size(13).text_color(t.muted).child(c.not_listed.length+" prior actions are not listed here. Their absence does not mark them complete.")))
        .when(d.report.items.some(i=>i.legacy),el=>el.child(div().text_size(12).text_color(t.muted).child("Older reports use their original wording; reworded actions may appear as new.")));
    }
    const items=visibleItems(d.items,this.filter);
    return v_flex().gap(12).when(Boolean(d.report.calendar),el=>el.child(div().text_size(13).text_color(t.muted).child(d.report.calendar)))
      .child(h_flex().gap(7).children([["open","Open"],["decision","Decisions"],["waiting","Waiting"],["snoozed","Reminders"],["done","Done"],["all","All"]].map(([id,label])=>this.button("filter-"+id,label,(_e,cx)=>{this.filter=id;cx.notify();},this.filter===id))))
      .children(items.map(i=>this.item(i))).when(!items.length,el=>el.child(div().text_size(14).text_color(t.muted).child("No items in this view.")))
      .when(d.followups.length>0,el=>el.child(div().text_size(16).font_semibold().child("Follow-ups from previous reports")))
      .children(visibleItems(d.followups,this.filter).map(i=>this.item(i,"followup-")));
  }
  render() {
    const t=theme(),d=this.data,report=d?.report,old=expired(report),unread=report&&!d.read;
    if(!props()?.overlay)return h_flex().id("intake-badge").size_full().px(14).gap(10).items_center().bg(t.surface).border_b(1).border_color(t.border).text_size(12)
      .on_click(()=>run("mod.open",{name:"work-intake"})).hover(s=>s.bg(t.hover))
      .child(div().font_semibold().text_color(this.error?t.blocked:t.accent).child(unread?"● Intake":"Intake"))
      .child(div().text_color(t.muted).child(this.error?"Delivery unavailable":!report?"Loading reports…":`${d.items.filter(i=>i.effective_status!=="done").length} follow-ups · ${report.display_time}`))
      .child(div().flex_1().truncate().text_color(t.muted).child(report?.summary||"Your briefings and follow-ups"))
      .child(div().text_color(t.accent).child(d?.reminders.length?`${d.reminders.length} reminders due`:old?"Previous brief":report?.coverage==="partial"?"Partial coverage":"Open Intake"));
    const position=d?.history.findIndex(r=>r.run_id===report?.run_id)??-1;
    const body=v_flex().id("intake-brief").size_full().p(24).gap(14).bg(t.surface).text_color(t.foreground)
      .child(h_flex().gap(16).items_center().justify_between()
        .child(v_flex().gap(5).child(div().text_size(23).font_semibold().child(this.source?"Source note":this.linking?"Link a vault action":"Intake"))
          .child(div().text_size(12).text_color(t.muted).child(report?report.display_time+" · "+(this.selected?"Historical report":old?"Previous briefing":"Latest briefing"):"Loading saved reports…")))
        .child(h_flex().gap(7).when(Boolean(this.source||this.linking),el=>el.child(this.button("intake-back","Back",(_e,cx)=>{this.source=null;this.linking=null;cx.notify();})))
          .when(Boolean(report),el=>el.child(this.button("intake-read",d.read?"Read":"Mark read",(_e,cx)=>this.act("read",null,cx))))
          .child(this.button("intake-reload","Reload",(_e,cx)=>this.refresh(cx))).child(this.button("intake-close","Close",()=>closeOverlay(props().overlay)))))
      .when(Boolean(this.error),el=>el.child(div().text_size(13).text_color(t.blocked).child(this.error)))
      .when(Boolean(this.message),el=>el.child(div().text_size(13).text_color(t.accent).child(this.message)));
    if(!report)return body.child(div().text_size(14).child(this.loading?"Loading saved report…":"No report is available yet."));
    body.child(h_flex().gap(7).items_center()
      .children([["now","Actions"],["changes","What changed"],["history","Reports ("+d.history.length+")"],["sources","Sources"],["report","Full report"]].map(([id,label])=>this.button("tab-"+id,label,(_e,cx)=>{this.section=id;this.source=null;this.linking=null;cx.notify();},this.section===id)))
      .child(div().flex_1()).when(position<d.history.length-1,el=>el.child(this.button("report-previous","Older",(_e,cx)=>this.chooseReport(d.history[position+1].run_id,cx))))
      .when(position>0,el=>el.child(this.button("report-next","Newer",(_e,cx)=>this.chooseReport(d.history[position-1].run_id,cx))))
      .when(Boolean(this.selected),el=>el.child(this.button("report-latest","Latest",(_e,cx)=>this.chooseReport(d.latest,cx)))));
    if(old||this.selected)body.child(div().text_size(12).text_color(t.muted).child("Historical report: its horizon has ended or a newer report exists. Follow-up controls retain your current state."));
    for(const pending of d.pending)body.child(h_flex().gap(10).items_center().child(div().text_size(12).text_color(t.blocked).child("A vault completion needs reconciliation."))
      .child(this.button("retry-"+pending.request.operation_id,"Retry saved completion",(_e,cx)=>this.submit(pending.request,cx)))
      .child(this.button("cancel-"+pending.request.operation_id,"Cancel if still open",(_e,cx)=>this.act("cancel-pending",null,cx,{pending_id:pending.request.operation_id}))));
    return body.child(div().id("intake-scroll").flex_1().overflow_y_scrollbar().child(this.content()))
      .child(div().text_size(11).text_color(t.dim).child(d.writer_record_present?"A vault writer record is present; completion waits for that writer.":"Weekdays 06:30–16:30 MT · Read state and task completion are separate"));
  }
}
