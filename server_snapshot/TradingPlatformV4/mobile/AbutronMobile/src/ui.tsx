import React from "react";
import {Pressable, StyleSheet, Text, TextInput, View} from "react-native";

export function Card({children}:{children:React.ReactNode}) {
  return <View style={styles.card}>{children}</View>;
}

export function Button({title,onPress,secondary=false,disabled=false}:{
  title:string;onPress:()=>void;secondary?:boolean;disabled?:boolean
}) {
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      style={[styles.button,secondary&&styles.secondary,disabled&&styles.disabled]}>
      <Text style={[styles.buttonText,secondary&&styles.secondaryText]}>{title}</Text>
    </Pressable>
  );
}

export function Field(props:any) {
  return <TextInput placeholderTextColor="#697586" {...props} style={[styles.input,props.style]} />;
}

export const styles=StyleSheet.create({
  screen:{flex:1,backgroundColor:"#07090c"},
  content:{padding:20,gap:14},
  brand:{fontSize:28,fontWeight:"900",color:"#d8b25c"},
  title:{fontSize:22,fontWeight:"800",color:"#f5f7fa"},
  text:{fontSize:14,color:"#d8dee8"},
  muted:{fontSize:13,color:"#8f9baa"},
  card:{backgroundColor:"#10151c",borderColor:"#222c38",borderWidth:1,borderRadius:16,padding:16,gap:8},
  input:{backgroundColor:"#0b1016",borderColor:"#263140",borderWidth:1,borderRadius:12,paddingHorizontal:14,paddingVertical:12,color:"#fff"},
  button:{backgroundColor:"#d8b25c",padding:13,borderRadius:12,alignItems:"center"},
  buttonText:{color:"#080a0d",fontWeight:"900"},
  secondary:{backgroundColor:"#18212c"},
  secondaryText:{color:"#fff"},
  disabled:{opacity:.45},
  row:{flexDirection:"row",gap:10,alignItems:"center"},
  tabs:{flexDirection:"row",gap:7,paddingHorizontal:12,paddingBottom:10},
  tab:{flex:1,paddingVertical:10,borderRadius:10,alignItems:"center",backgroundColor:"#111820"},
  tabActive:{backgroundColor:"#d8b25c"},
  tabText:{fontSize:12,color:"#cbd5e1",fontWeight:"700"},
  tabTextActive:{color:"#07090c"},
  good:{color:"#74d68d",fontWeight:"800"},
  warn:{color:"#f1c36c",fontWeight:"800"},
  danger:{color:"#ff8e8e",fontWeight:"800"},
});
