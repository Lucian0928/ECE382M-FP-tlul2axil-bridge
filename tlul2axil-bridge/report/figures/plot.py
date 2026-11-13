import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
rows=[l.split()[1:] for l in open("wave.txt")]
names=["cyc","a_valid","a_ready","a_opcode","m_awvalid","m_awready","m_wvalid","m_wready","m_bvalid","m_bready",
       "m_arvalid","m_arready","m_rvalid","m_rready","d_valid","d_ready","d_error","d_opcode","d_data","dfire","state"]
cols={n:[r[i] for r in rows] for i,n in enumerate(names)}
cyc=[int(c) for c in cols["cyc"]]; N=len(cyc)
show=[("a_valid","b"),("a_ready","b"),("a_opcode","bus"),("m_awvalid","b"),("m_awready","b"),("m_wvalid","b"),("m_wready","b"),
      ("m_bvalid","b"),("m_bready","b"),("m_arvalid","b"),("m_arready","b"),("m_rvalid","b"),("m_rready","b"),
      ("d_valid","b"),("d_ready","b"),("d_opcode","bus"),("d_data","bus"),("state","bus")]
stname={"0":"IDLE","1":"RD","2":"WR","3":"RESP"}
fig,ax=plt.subplots(figsize=(10,6.2))
H=0.6
for k,(n,t) in enumerate(show):
    y=-k
    v=cols[n]
    if t=="b":
        xs=[];ys=[]
        for i in range(N):
            lv=int(v[i]); xs+= [i,i+1]; ys+=[y+lv*H,y+lv*H]
        ax.plot(xs,ys,color="#1f4e79",lw=1.4)
    else:
        i=0
        while i<N:
            j=i
            while j+1<N and v[j+1]==v[i]: j+=1
            lab=stname[v[i]] if n=="state" else v[i]
            if n=="d_data": lab=lab.upper() if lab!="00000000" else "0"
            ax.add_patch(plt.Polygon([(i+0.1,y),(i,y+H/2),(i+0.1,y+H),(j+0.9,y+H),(j+1,y+H/2),(j+0.9,y)],
                         closed=True,fill=True,fc="#eef3f8",ec="#1f4e79",lw=1.0))
            ax.text((i+j+1)/2,y+H/2,lab,ha="center",va="center",fontsize=7)
            i=j+1
    ax.text(-0.3,y+H/2,n,ha="right",va="center",fontsize=8.5,family="monospace")
for i in range(N+1): ax.axvline(i,color="#dddddd",lw=0.5,zorder=0)
for i in range(N): ax.text(i+0.5,1.0,str(cyc[i]),ha="center",fontsize=7,color="#666")
def mark(c,txt,yrow):
    i=cyc.index(c); ax.annotate(txt,xy=(i+0.5,-yrow+H+0.05),xytext=(i+0.5,-yrow+H+0.55),ha="center",fontsize=7,color="#b03030",
        arrowprops=dict(arrowstyle="->",color="#b03030",lw=0.8))
ax.text(-0.3,1.0,"cycle",ha="right",fontsize=8,color="#666")
ax.set_xlim(-3.2,N+0.2); ax.set_ylim(-len(show)+0.2,1.5); ax.axis("off")
plt.tight_layout(); plt.savefig("waveform.png",dpi=220)

# ---------- block diagram ----------
fig,ax=plt.subplots(figsize=(10,3.6)); ax.axis("off"); ax.set_xlim(0,100); ax.set_ylim(0,36)
def box(x,y,w,h,t,fc="#eef3f8"):
    ax.add_patch(FancyBboxPatch((x,y),w,h,boxstyle="round,pad=0.4,rounding_size=1.2",fc=fc,ec="#1f4e79",lw=1.2))
    ax.text(x+w/2,y+h/2,t,ha="center",va="center",fontsize=8.5)
def arr(x1,y1,x2,y2,t="",dy=1.2):
    ax.annotate("",xy=(x2,y2),xytext=(x1,y1),arrowprops=dict(arrowstyle="->",color="#333",lw=1.1))
    if t: ax.text((x1+x2)/2,(y1+y2)/2+dy,t,ha="center",fontsize=7.5)
box(1,12,12,12,"TL-UL\nhost\n(master)",fc="#f4f4f4")
box(87,12,12,12,"AXI4-Lite\nslave\n(peripheral)",fc="#f4f4f4")
ax.add_patch(FancyBboxPatch((20,2),60,32,boxstyle="round,pad=0.4,rounding_size=1.5",fc="white",ec="#1f4e79",lw=1.6,ls="--"))
ax.text(50,32.3,"tlul2axil bridge",ha="center",fontsize=9.5,weight="bold",color="#1f4e79")
box(23,17,17,11,"Request capture\n+ decode /\nlegality check")
box(46,22,16,7.5,"Write ctrl\n(aw_done, w_done)")
box(46,11,16,7.5,"Read ctrl\n(ar_done)")
box(23,4,17,9,"Response register\n(d_* , registered)")
box(64,24,10,6,"FSM\nIDLE/RD/WR/RESP",fc="#fff8e6")
arr(13,21,23,21,"A: Get/PutFull/\nPutPartial",dy=1.5)
arr(40,24,46,25.5); arr(40,20,46,15)
arr(62,27,87,22,"AW, W  →",dy=0.8); arr(87,19,62,24.5,"←  B",dy=-2.5)
arr(62,15,87,16.5,"AR  →",dy=0.8); arr(87,13,62,12.5,"←  R",dy=-2.6)
arr(54,11,40,9,"",); arr(31.5,17,31.5,13,"")
ax.text(33.5,14.6,"local error",fontsize=7,color="#b03030")
arr(23,8.5,13,15,"D: AccessAck/\nAccessAckData",dy=-5)
plt.savefig("block.png",dpi=220,bbox_inches="tight")
