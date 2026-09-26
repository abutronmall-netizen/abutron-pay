import React, {useEffect, useState} from "react";
import {
  ActivityIndicator,
  Alert,
  FlatList,
  SafeAreaView,
  ScrollView,
  Switch,
  Text,
  View,
} from "react-native";
import {clearToken, getToken, login, register, request} from "./src/api";
import {Bootstrap, Trade} from "./src/types";
import {Button, Card, Field, styles} from "./src/ui";

type Tab="home"|"trades"|"alerts"|"support"|"profile";

export default function App(){
  const [booting,setBooting]=useState(true);
  const [authed,setAuthed]=useState(false);
  const [tab,setTab]=useState<Tab>("home");
  const [data,setData]=useState<Bootstrap|null>(null);
  const [trades,setTrades]=useState<Trade[]>([]);
  const [error,setError]=useState("");

  async function refresh(){
    try{
      setError("");
      const b=await request<Bootstrap>("/v1/mobile/bootstrap");
      setData(b);
      const t=await request<Trade[]>("/v1/customer/trades?limit=100");
      setTrades(t);
    }catch(e:any){setError(e.message)}
  }

  useEffect(()=>{
    (async()=>{
      const token=await getToken();
      if(token){
        setAuthed(true);
        await refresh();
      }
      setBooting(false);
    })();
  },[]);

  if(booting){
    return <SafeAreaView style={styles.screen}><View style={styles.content}><ActivityIndicator/></View></SafeAreaView>;
  }
  if(!authed){
    return <AuthScreen onAuthed={async()=>{setAuthed(true);await refresh();}}/>;
  }

  async function logout(){
    await clearToken();setAuthed(false);setData(null);setTrades([]);
  }

  return (
    <SafeAreaView style={styles.screen}>
      <View style={{paddingHorizontal:20,paddingTop:18,paddingBottom:8}}>
        <Text style={styles.brand}>ABUTRON FX</Text>
        <Text style={styles.muted}>Step 26A · Customer Mobile</Text>
      </View>
      {!!error && <View style={{paddingHorizontal:20}}><Text style={styles.danger}>{error}</Text></View>}
      <View style={styles.tabs}>
        {(["home","trades","alerts","support","profile"] as Tab[]).map(x=>(
          <ButtonTab key={x} tab={x} current={tab} onPress={()=>setTab(x)}/>
        ))}
      </View>
      <View style={{flex:1}}>
        {tab==="home"&&<Home data={data} refresh={refresh}/>}
        {tab==="trades"&&<Trades trades={trades}/>}
        {tab==="alerts"&&<Alerts data={data} refresh={refresh}/>}
        {tab==="support"&&<Support refresh={refresh}/>}
        {tab==="profile"&&<Profile data={data} refresh={refresh} logout={logout}/>}
      </View>
    </SafeAreaView>
  );
}

function ButtonTab({tab,current,onPress}:{tab:Tab;current:Tab;onPress:()=>void}){
  const active=tab===current;
  return (
    <Text
      onPress={onPress}
      style={[
        styles.tabText,
        {flex:1,textAlign:"center",paddingVertical:11,borderRadius:10,backgroundColor:active?"#d8b25c":"#111820"},
        active&&styles.tabTextActive
      ]}>
      {tab.toUpperCase()}
    </Text>
  );
}

function AuthScreen({onAuthed}:{onAuthed:()=>void}){
  const [mode,setMode]=useState<"login"|"register">("login");
  const [email,setEmail]=useState("");
  const [password,setPassword]=useState("");
  const [name,setName]=useState("");
  const [phone,setPhone]=useState("");
  const [terms,setTerms]=useState(false);
  const [risk,setRisk]=useState(false);
  const [busy,setBusy]=useState(false);
  const [msg,setMsg]=useState("");

  async function submit(){
    setBusy(true);setMsg("");
    try{
      if(mode==="register"){
        if(!terms||!risk) throw new Error("Terms and trading-risk acceptance are required.");
        await register({email,password,full_name:name,phone,terms_accepted:terms,risk_accepted:risk});
        setMsg("Registration complete. Your license begins pending. Sign in to continue.");
        setMode("login");
      }else{
        await login(email,password);await onAuthed();
      }
    }catch(e:any){setMsg(e.message)}
    finally{setBusy(false)}
  }

  return (
    <SafeAreaView style={styles.screen}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.brand}>ABUTRON FX</Text>
        <Text style={styles.title}>{mode==="login"?"Customer Login":"Create Account"}</Text>
        <Card>
          {mode==="register"&&<>
            <Field value={name} onChangeText={setName} placeholder="Full name"/>
            <Field value={phone} onChangeText={setPhone} placeholder="Telephone"/>
          </>}
          <Field value={email} onChangeText={setEmail} autoCapitalize="none" keyboardType="email-address" placeholder="Email"/>
          <Field value={password} onChangeText={setPassword} secureTextEntry placeholder="Password"/>
          {mode==="register"&&<>
            <View style={styles.row}><Switch value={terms} onValueChange={setTerms}/><Text style={styles.text}>I accept the Terms & Conditions.</Text></View>
            <View style={styles.row}><Switch value={risk} onValueChange={setRisk}/><Text style={styles.text}>I accept the trading-risk disclosure.</Text></View>
          </>}
          {!!msg&&<Text style={styles.warn}>{msg}</Text>}
          <Button title={busy?"Working...":mode==="login"?"Login":"Register"} onPress={submit} disabled={busy}/>
          <Button secondary title={mode==="login"?"Create account":"Back to login"} onPress={()=>setMode(mode==="login"?"register":"login")}/>
        </Card>
      </ScrollView>
    </SafeAreaView>
  );
}

function Home({data,refresh}:{data:Bootstrap|null;refresh:()=>void}){
  if(!data)return <Loading/>;
  const license=data.license?.status||"none";
  return <ScrollView contentContainerStyle={styles.content}>
    <Card>
      <Text style={styles.title}>Welcome, {data.user.full_name}</Text>
      <Text style={styles.muted}>Execution is intentionally not exposed in Step 26A.</Text>
      <Text style={data.platform.execution_enabled?styles.danger:styles.good}>
        Platform execution: {data.platform.execution_enabled?"ENABLED":"DISABLED"}
      </Text>
      <Text style={styles.warn}>Mobile trading mode: {data.platform.mobile_trading_mode}</Text>
    </Card>
    <Card><Text style={styles.title}>License</Text><Text style={styles.text}>{license.toUpperCase()}</Text></Card>
    <Card><Text style={styles.title}>Trading Accounts</Text>
      {data.accounts.length===0?<Text style={styles.muted}>No account linked.</Text>:
        data.accounts.map(a=><View key={a.id}>
          <Text style={styles.text}>{a.broker} · {a.login || "No login"}</Text>
          <Text style={styles.muted}>{a.symbol} · Bot: {a.current_tier || "Pending assignment"} · Equity: {a.equity??"Awaiting broker sync"}</Text>
        </View>)}
    </Card>
    <Card><Text style={styles.title}>Support</Text><Text style={styles.text}>Open tickets: {data.support.open_count}</Text></Card>
    <Button title="Refresh" onPress={refresh}/>
  </ScrollView>
}

function Trades({trades}:{trades:Trade[]}){
  return <FlatList contentContainerStyle={styles.content} data={trades} keyExtractor={x=>String(x.id)}
    ListEmptyComponent={<Card><Text style={styles.muted}>No recorded trades yet.</Text></Card>}
    renderItem={({item})=><Card>
      <Text style={styles.title}>{item.symbol} · {item.side}</Text>
      <Text style={styles.text}>{item.state} · {item.tier||"Unassigned"}</Text>
      <Text style={styles.muted}>Volume {item.volume} · Entry {item.entry} · P/L {item.profit}</Text>
    </Card>}/>;
}

function Alerts({data,refresh}:{data:Bootstrap|null;refresh:()=>void}){
  if(!data)return <Loading/>;
  async function mark(id:number){
    await request(`/v1/notifications/${id}/read`,{method:"PUT"});
    await refresh();
  }
  return <FlatList contentContainerStyle={styles.content} data={data.notifications} keyExtractor={x=>String(x.id)}
    ListEmptyComponent={<Card><Text style={styles.muted}>No notifications.</Text></Card>}
    renderItem={({item})=><Card>
      <Text style={styles.title}>{item.title}</Text><Text style={styles.text}>{item.body}</Text>
      <Text style={styles.muted}>{item.read?"Read":"Unread"}</Text>
      {!item.read&&<Button secondary title="Mark read" onPress={()=>mark(item.id)}/>}
    </Card>}/>;
}

function Support({refresh}:{refresh:()=>void}){
  const [subject,setSubject]=useState("");const [message,setMessage]=useState("");const [status,setStatus]=useState("");
  async function submit(){
    try{
      await request("/v1/support/tickets",{method:"POST",body:JSON.stringify({subject,message,priority:"normal"})});
      setSubject("");setMessage("");setStatus("Support ticket created.");await refresh();
    }catch(e:any){setStatus(e.message)}
  }
  return <ScrollView contentContainerStyle={styles.content}>
    <Card>
      <Text style={styles.title}>Contact Abutron Support</Text>
      <Field value={subject} onChangeText={setSubject} placeholder="Subject"/>
      <Field value={message} onChangeText={setMessage} placeholder="Describe the issue" multiline style={{minHeight:120,textAlignVertical:"top"}}/>
      {!!status&&<Text style={styles.warn}>{status}</Text>}
      <Button title="Submit Ticket" onPress={submit}/>
    </Card>
  </ScrollView>
}

function Profile({data,refresh,logout}:{data:Bootstrap|null;refresh:()=>void;logout:()=>void}){
  const [name,setName]=useState(data?.user.full_name||"");const [phone,setPhone]=useState(data?.user.phone||"");
  const [notice,setNotice]=useState(data?.preferences.notifications_enabled??true);
  async function save(){
    await request("/v1/customer/profile",{method:"PATCH",body:JSON.stringify({full_name:name,phone,notifications_enabled:notice})});
    await refresh();Alert.alert("Saved","Profile updated.");
  }
  return <ScrollView contentContainerStyle={styles.content}>
    <Card><Text style={styles.title}>Profile</Text>
      <Field value={name} onChangeText={setName} placeholder="Full name"/>
      <Field value={phone} onChangeText={setPhone} placeholder="Telephone"/>
      <View style={styles.row}><Switch value={notice} onValueChange={setNotice}/><Text style={styles.text}>Notifications enabled</Text></View>
      <Button title="Save" onPress={save}/>
    </Card>
    <Button secondary title="Logout" onPress={logout}/>
  </ScrollView>
}

function Loading(){return <View style={styles.content}><ActivityIndicator/></View>}
