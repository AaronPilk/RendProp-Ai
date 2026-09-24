import {createStudioAuth} from "../src/data/auth-client";
const auth=createStudioAuth({supabaseUrl:"https://auth-fixture.supabase.co",publishableKey:"sb_publishable_ISOLATED_FIXTURE_NOT_REAL",redirectTo:window.location.origin+"/tests/auth-fixture.html"},localStorage);
const state=document.getElementById("state")!;
auth.onAuthStateChange((_event,session)=>{state.textContent=session?.user.id??"Signed out";});
document.getElementById("logout")!.addEventListener("click",()=>{void auth.signOut({scope:"local"});});
void auth.getSession().then(({data,error})=>{state.textContent=error?"Auth error":data.session?.user.id??"Signed out";});
